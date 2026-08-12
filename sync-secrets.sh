#!/usr/bin/env bash
# Create/update the per-namespace matrix-webhook-url secret from secrets/<ns>.env
# + url.template + --cluster. One namespace, or --all (every secrets/*.env).
# Dry-run by default; pass --apply to actually write.
#
# Direction is one-way: local secrets/<ns>.env -> cluster. Local is the source of
# truth; an existing cluster secret is OVERWRITTEN to match it.
set -euo pipefail

usage() {
  echo "usage: $0 <kubeconfig> --cluster <name> (<namespace> | --all) [--apply]" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
KC="$1"; shift
[[ -f "$KC" ]] || { echo "kubeconfig not found: $KC" >&2; exit 1; }

CLUSTER=""; APPLY=0; ALL=0; NS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="${2:-}"; shift 2 ;;
    --all)     ALL=1; shift ;;
    --apply)   APPLY=1; shift ;;
    -*)        usage ;;
    *)         NS="$1"; shift ;;
  esac
done
[[ -n "$CLUSTER" ]] || { echo "--cluster <name> is required" >&2; usage; }
if (( ALL )); then
  [[ -z "$NS" ]] || { echo "pass either <namespace> or --all, not both" >&2; usage; }
else
  [[ -n "$NS" ]] || { echo "specify a <namespace> or --all" >&2; usage; }
fi

cd "$(dirname "$0")"
command -v envsubst >/dev/null || { echo "envsubst not found (install gettext)" >&2; exit 1; }
[[ -f url.template ]] || { echo "missing url.template" >&2; exit 1; }
k() { kubectl --kubeconfig="$KC" "$@"; }
export CLUSTER

DRY=(--dry-run=server)
if (( APPLY )); then
  DRY=()
  echo "=== APPLYING secrets to the cluster (real changes) ==="
else
  echo "=== DRY RUN: nothing will change. Lines below show what WOULD change. Re-run with --apply to apply. ==="
fi

sync_ns() {
  local ns="$1" env="secrets/$CLUSTER/$1.env"
  [[ -f "$env" ]] || { echo "no $env (cluster '$CLUSTER', namespace '$ns')" >&2; return 1; }
  (
    set -a; . "./$env"; set +a
    : "${KEY:?KEY missing in $env}" "${ROOM_ID:?ROOM_ID missing in $env}"
    # command substitution strips the template's trailing newline
    url="$(envsubst '${KEY} ${ROOM_ID} ${CLUSTER}' < url.template)"
    echo ">> matrix-webhook-url in namespace '$ns' (cluster=$CLUSTER)"
    k create secret generic matrix-webhook-url -n "$ns" \
      --from-literal=url="$url" --dry-run=client -o yaml | k apply -f - "${DRY[@]}"
  )
}

if (( ALL )); then
  shopt -s nullglob
  found=0
  for env in "secrets/$CLUSTER"/*.env; do
    sync_ns "$(basename "$env" .env)"
    found=1
  done
  (( found )) || { echo "no env files in secrets/$CLUSTER/" >&2; exit 1; }
else
  sync_ns "$NS"
fi

(( APPLY )) || echo "=== DRY RUN complete — no changes were made. Re-run with --apply to apply. ==="
