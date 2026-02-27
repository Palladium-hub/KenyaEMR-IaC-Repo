#!/usr/bin/env bash
set -euo pipefail

DEST="/usr/share/nginx/html/openmrs/spa"

echo "🔍 Discovering KenyaEMR tenant frontend deployments..."

mapfile -t DEPS < <(
  kubectl get deploy -A --no-headers |
  awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-frontend$/ {print $1"\t"$2}'
)

if [ ${#DEPS[@]} -eq 0 ]; then
  echo "❌ No frontend deployments found."
  exit 1
fi

declare -A IS_PERSISTED

echo
i=1
for d in "${DEPS[@]}"; do
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"

  if kubectl get deploy -n "$NS" "$DEP" -o json |
     jq -e ".spec.template.spec.containers[0].volumeMounts[]? |
            select(.mountPath==\"$DEST\")" >/dev/null 2>&1; then
    STATUS="✅ persisted"
    IS_PERSISTED["$i"]="yes"
  else
    STATUS="❌ not persisted"
    IS_PERSISTED["$i"]="no"
  fi

  printf "[%d] %s / %s  →  %s\n" "$i" "$NS" "$DEP" "$STATUS"
  i=$((i+1))
done

echo
echo "Choose deployments to UN-persist:"
echo "  - all     → un-persist ALL persisted"
echo "  - 1,3,5   → multi-select"
read -p "👉 Selection: " SEL

TARGETS=()

if [[ "$SEL" =~ ^[Aa][Ll][Ll]$ ]]; then
  for n in $(seq 1 ${#DEPS[@]}); do
    [ "${IS_PERSISTED[$n]}" = "yes" ] && TARGETS+=("$n")
  done
else
  IFS=',' read -ra PARTS <<< "$SEL"
  for p in "${PARTS[@]}"; do
    n="$(echo "$p" | tr -d '[:space:]')"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "❌ Invalid input: $n"; exit 1; }
    TARGETS+=("$n")
  done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "✅ Nothing to un-persist."
  exit 0
fi

echo
echo "🚨 You are about to REMOVE SPA persistence from selected deployments."
read -p "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

echo

for idx in "${TARGETS[@]}"; do
  d="${DEPS[$((idx-1))]}"
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"
  PVC="${DEP}-spa-pvc"

  echo "--------------------------------------------"
  echo "➡️  Un-persisting $NS / $DEP"

  if [ "${IS_PERSISTED[$idx]}" = "no" ]; then
    echo "ℹ️  Already not persisted — skipping."
    continue
  fi

  echo "🔧 Removing PVC mount from deployment..."

  kubectl patch deployment "$DEP" -n "$NS" --type='json' -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts",
     "value":null}
  ]' || true

  kubectl patch deployment "$DEP" -n "$NS" --type='json' -p='[
    {"op":"remove","path":"/spec/template/spec/volumes",
     "value":null}
  ]' || true

  echo "🔄 Restarting deployment..."
  kubectl rollout restart deployment "$DEP" -n "$NS"
  kubectl rollout status deployment "$DEP" -n "$NS"

  echo "🗑️  PVC $PVC still exists."

  read -p "❓ Delete PVC $PVC as well? [y/N]: " DELPVC
  if [[ "$DELPVC" =~ ^[Yy]$ ]]; then
    kubectl delete pvc "$PVC" -n "$NS" || true
    echo "✅ PVC deleted."
  else
    echo "ℹ️  PVC kept (can re-enable persistence later)."
  fi

  echo "✅ $DEP is now NOT persisted"
done

echo
echo "🎉 Un-persist operation completed"
echo "ℹ️  Frontends now serve SPA from Docker image again"
