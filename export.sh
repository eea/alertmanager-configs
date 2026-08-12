#!/usr/bin/env bash
# One-time bootstrap: pull live AlertmanagerConfigs into this repo, strip server
# fields, move key/room_id into per-cluster secrets, and swap url -> urlSecret.
# Requires yq (mikefarah or python/jq) and GNU grep (grep -P). Run once, then hand-maintain.
#
# Namespace list is resolved in this order:
#   1. CLI args:                 ./export.sh <kubeconfig> graylog jenkins-master
#   2. a file via -f <file>:     ./export.sh <kubeconfig> -f namespaces.01prod
#   3. cluster discovery via `kubectl get namespaces` (needs cluster-scope access)
# Kubernetes offers no way to enumerate "namespaces I can access" without that
# cluster permission, so with namespace-scoped RBAC use option 1 or 2. The file is
# one namespace per line (# comments and blank lines ignored) — keep one per
# cluster, e.g. namespaces.01prod, namespaces.02dev.
set -euo pipefail

usage() { echo "usage: $0 <kubeconfig> [-f namespaces-file] [namespace ...]" >&2; exit 1; }

[[ $# -ge 1 ]] || usage
KC="$1"; shift
[[ "$KC" = /* ]] || KC="$PWD/$KC"                 # absolutize before we cd
[[ -f "$KC" ]] || { echo "kubeconfig not found: $KC" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found (install mikefarah/yq or python-yq)" >&2; exit 1; }

NSFILE=""
NAMESPACES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--namespaces-file) NSFILE="${2:?-f needs a file path}"; shift 2 ;;
    -*)                   echo "unknown option: $1" >&2; usage ;;
    *)                    NAMESPACES+=("$1"); shift ;;
  esac
done
[[ -z "$NSFILE" || "$NSFILE" = /* ]] || NSFILE="$PWD/$NSFILE"   # absolutize before we cd

cd "$(dirname "$0")"
k() { kubectl --kubeconfig="$KC" "$@"; }
mkdir -p configs

# yq flavor: mikefarah (Go) emits YAML by default and prints raw scalars; the
# Python/jq wrapper needs -y (YAML out) and -r (raw scalar out).
YAML_OUT=(); RAW=()
if ! yq --help 2>&1 | grep -qi mikefarah; then YAML_OUT=(-y); RAW=(-r); fi

# Strip server-generated fields, then stamp our managed-by label.
STRIP='del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.generation, .metadata.creationTimestamp, .status, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration") | .metadata.labels."managed-by" = "alertmanager-configs"'

# Replace each webhookConfig's plaintext url with a urlSecret reference.
SWAP='(.spec.receivers[].webhookConfigs[]? | select(has("url"))) |= (del(.url) + {urlSecret:{name:"matrix-webhook-url",key:"url"}})'

nsname='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'

# Build the <namespace>/<name> list. Captured into a variable (not piped) so a
# kubectl failure aborts here under `set -e` instead of silently yielding nothing.
get_list() {
  local ns nss discover=0
  if (( ${#NAMESPACES[@]} > 0 )); then
    nss="$(printf '%s\n' "${NAMESPACES[@]}")"                      # 1. explicit args
  elif [[ -n "$NSFILE" ]]; then
    [[ -f "$NSFILE" ]] || { echo "namespaces file not found: $NSFILE" >&2; exit 1; }  # 2. -f file
    nss="$(grep -vE '^[[:space:]]*(#|$)' "$NSFILE" || true)"
    [[ -n "$nss" ]] || { echo "$NSFILE has no entries" >&2; exit 1; }
  else
    nss="$(k get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || {  # 3. discovery
      echo "No namespaces given (args or -f <file>), and cannot list namespaces at cluster scope." >&2
      echo "List them in a file (one per line) and pass it, or pass them explicitly:" >&2
      echo "  $0 <kubeconfig> -f namespaces.01prod" >&2
      echo "  $0 <kubeconfig> graylog jenkins-master" >&2
      exit 1
    }
    discover=1
  fi
  # For an explicit list (args/file) a read failure is a real error (abort under
  # set -e). For discovery we probe every namespace and skip the unreadable ones.
  while read -r ns; do
    [[ -n "$ns" ]] || continue
    if (( discover )); then
      k get alertmanagerconfig -n "$ns" -o jsonpath="$nsname" 2>/dev/null || true
    else
      k get alertmanagerconfig -n "$ns" -o jsonpath="$nsname"
    fi
    echo
  done <<< "$nss"
}
list="$(get_list)"

count=0
while IFS=/ read -r ns name; do
  [[ -n "$ns" && -n "$name" ]] || continue
  cfg="configs/$ns.yaml"
  echo ">> $ns/$name -> $cfg"
  k get alertmanagerconfig "$name" -n "$ns" -o yaml | yq "${YAML_OUT[@]}" "$STRIP" > "$cfg"
  count=$((count + 1))

  # Pull the plaintext webhook URL out into a per-cluster secret, then swap url -> urlSecret.
  url="$(yq "${RAW[@]}" '.spec.receivers[].webhookConfigs[]?.url // empty' "$cfg" | head -1)"
  [[ -n "$url" ]] || continue
  key="$(grep -oP '(?<=[?&]key=)[^&]*' <<<"$url" || true)"
  room="$(grep -oP '(?<=[?&]room_id=)[^&]*' <<<"$url" || true)"
  cluster="$(grep -oP '(?<=[?&]cluster=)[^&]*' <<<"$url" || true)"
  if [[ -z "$key" || -z "$room" || -z "$cluster" ]]; then
    echo "   ! could not parse key/room_id/cluster from URL — left url as-is in $cfg" >&2
    continue
  fi
  mkdir -p "secrets/$cluster"
  printf 'KEY=%s\nROOM_ID=%s\n' "$key" "$room" > "secrets/$cluster/$ns.env"
  yq "${YAML_OUT[@]}" "$SWAP" "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  echo "   secrets -> secrets/$cluster/$ns.env  |  url -> urlSecret"
done <<< "$list"

if (( count == 0 )); then
  echo "No AlertmanagerConfigs found." >&2
  exit 0
fi