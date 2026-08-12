#!/usr/bin/env bash
# Apply AlertmanagerConfig routing to a cluster. Dry-run by default; --apply to write.
# Secrets are managed separately by ./sync-secrets.sh; this only warns if one is missing.
#
# Scope (exactly one required):
#   --all                 apply every configs/*.yaml
#   -f <file>             apply only the namespaces listed in <file> (one per line)
#   <namespace> [ns ...]  apply only these namespaces
# Note: never prunes — a deleted config file is NOT removed from the cluster.
# Pruning (reconciling deletions) is a deliberate feature for later.
set -euo pipefail

usage() { echo "usage: $0 <kubeconfig> (--all | -f <file> | <namespace> ...) [--apply]" >&2; exit 1; }

[[ $# -ge 1 ]] || usage
KC="$1"; shift
[[ "$KC" = /* ]] || KC="$PWD/$KC"                 # absolutize before we cd
[[ -f "$KC" ]] || { echo "kubeconfig not found: $KC" >&2; exit 1; }

ALL=0; APPLY=0; NSFILE=""; NAMESPACES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)                ALL=1; shift ;;
    -f|--namespaces-file) NSFILE="${2:?-f needs a file path}"; shift 2 ;;
    --apply)              APPLY=1; shift ;;
    -*)                   echo "unknown option: $1" >&2; usage ;;
    *)                    NAMESPACES+=("$1"); shift ;;
  esac
done
[[ -z "$NSFILE" || "$NSFILE" = /* ]] || NSFILE="$PWD/$NSFILE"   # absolutize before we cd

# Exactly one scope source.
sources=0
(( ALL ))                 && sources=$((sources + 1))
[[ -n "$NSFILE" ]]        && sources=$((sources + 1))
(( ${#NAMESPACES[@]} ))   && sources=$((sources + 1))
(( sources == 1 )) || usage

cd "$(dirname "$0")"
k() { kubectl --kubeconfig="$KC" "$@"; }

# Resolve the set of config files to apply.
targets=()
add_ns() {
  local ns="$1" f="configs/$1.yaml"
  [[ -f "$f" ]] || { echo "no config for namespace '$ns' ($f)" >&2; exit 1; }
  targets+=("$f")
}
if (( ALL )); then
  shopt -s nullglob
  targets=(configs/*.yaml)
  (( ${#targets[@]} )) || { echo "no configs/*.yaml found" >&2; exit 1; }
else
  if [[ -n "$NSFILE" ]]; then
    [[ -f "$NSFILE" ]] || { echo "namespaces file not found: $NSFILE" >&2; exit 1; }
    nslist="$(grep -vE '^[[:space:]]*(#|$)' "$NSFILE" || true)"
    [[ -n "$nslist" ]] || { echo "$NSFILE has no entries" >&2; exit 1; }
    while read -r ns; do [[ -n "$ns" ]] && add_ns "$ns"; done <<< "$nslist"
  else
    for ns in "${NAMESPACES[@]}"; do add_ns "$ns"; done
  fi
fi

# Skip namespaces whose webhook-url secret doesn't exist — applying them would
# create a non-functional config (the operator can't resolve the urlSecret).
applicable=()
for cfg in "${targets[@]}"; do
  ns="$(basename "$cfg" .yaml)"
  if k get secret matrix-webhook-url -n "$ns" >/dev/null 2>&1; then
    applicable+=("$cfg")
  else
    echo "SKIP '$ns': secret 'matrix-webhook-url' not found —" \
         "create it with: ./sync-secrets.sh $KC --cluster <name> $ns --apply" >&2
  fi
done
(( ${#applicable[@]} )) || { echo "Nothing to apply — no targeted namespace has its secret." >&2; exit 0; }
targets=("${applicable[@]}")

# --- routing configs ---
DRY=(--dry-run=server)
if (( APPLY )); then
  DRY=()
  echo "=== APPLYING routing to the cluster (real changes) ==="
else
  echo "=== DRY RUN: nothing will change. Lines below show what WOULD change. Re-run with --apply to apply. ==="
fi
echo "targeting: ${targets[*]}"

# No --prune for now: apply never deletes configs. (Prune is a later feature.)
cmd=(apply)
for f in "${targets[@]}"; do cmd+=(-f "$f"); done
cmd+=("${DRY[@]}")
k "${cmd[@]}"

(( APPLY )) || echo "=== DRY RUN complete — no changes were made. Re-run with --apply to apply. ==="
