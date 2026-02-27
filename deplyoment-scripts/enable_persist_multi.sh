#!/usr/bin/env bash
set -euo pipefail

# Where SPA lives inside the nginx container
DEST="${DEST:-/usr/share/nginx/html/openmrs/spa}"

# PVC settings
SC="${SC:-microk8s-hostpath}"
SIZE="${SIZE:-2Gi}"

# Optional modes
DRY_RUN="${DRY_RUN:-0}"     # 1 = don't patch/apply/restart, only show what would happen
PREFLIGHT="${PREFLIGHT:-0}" # 1 = validations only (same as dry-run but stricter exit on errors)

# ---- kubectl resolver (works even if PATH is minimal) ----
KUBECTL=""
for c in kubectl "microk8s kubectl" microk8s.kubectl; do
  if command -v ${c%% *} >/dev/null 2>&1; then
    KUBECTL="$c"
    break
  fi
done
for p in /snap/microk8s/current/kubectl /usr/local/bin/kubectl /usr/bin/kubectl; do
  if [ -z "$KUBECTL" ] && [ -x "$p" ]; then
    KUBECTL="$p"; break
  fi
done
[ -n "$KUBECTL" ] || { echo "❌ kubectl not found in PATH/common locations."; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ] || [ "$PREFLIGHT" = "1" ]; then
    echo "🧪 DRY: $*"
    return 0
  fi
  eval "$@"
}

echo "🔍 Discovering KenyaEMR tenant frontend deployments..."
echo "   DEST=$DEST"
echo "   SC=$SC SIZE=$SIZE"
echo "   kubectl=$KUBECTL"
echo

mapfile -t DEPS < <(
  $KUBECTL get deploy -A --no-headers 2>/dev/null |
  awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-frontend$/ {print $1"\t"$2}'
)

if [ ${#DEPS[@]} -eq 0 ]; then
  echo "❌ No kenyaemr-tenant-* frontend deployments found."
  exit 1
fi

# -------- helpers (no jq) --------

# Returns the volume name mounted at $DEST (or empty)
mount_volume_at_dest() {
  local ns="$1" dep="$2"
  $KUBECTL -n "$ns" get deploy "$dep" -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.mountPath}{"|"}{.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' -v p="$DEST" '$1==p{print $2; exit}'
}

# Returns PVC claimName for a given volume (or empty)
pvc_for_volume() {
  local ns="$1" dep="$2" vol="$3"
  $KUBECTL -n "$ns" get deploy "$dep" -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"|"}{.persistentVolumeClaim.claimName}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' -v v="$vol" '$1==v && $2!=""{print $2; exit}'
}

is_persisted() {
  local ns="$1" dep="$2"
  local vol claim
  vol="$(mount_volume_at_dest "$ns" "$dep" || true)"
  [ -n "$vol" ] || return 1
  claim="$(pvc_for_volume "$ns" "$dep" "$vol" || true)"
  [ -n "$claim" ]
}

ensure_pvc() {
  local ns="$1" pvc="$2"
  if $KUBECTL -n "$ns" get pvc "$pvc" >/dev/null 2>&1; then
    echo "ℹ️  PVC $pvc already exists."
    return 0
  fi
  echo "📦 Creating PVC $pvc ..."
  run "cat <<EOF | $KUBECTL apply -n \"$ns\" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $SC
  resources:
    requests:
      storage: $SIZE
EOF"
}

# Add volume if missing (idempotent-ish)
add_volume_if_missing() {
  local ns="$1" dep="$2" volname="$3" pvc="$4"
  if $KUBECTL -n "$ns" get deploy "$dep" -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null \
     | grep -qx "$volname"; then
    return 0
  fi

  local vols
  vols="$($KUBECTL -n "$ns" get deploy "$dep" -o jsonpath='{.spec.template.spec.volumes}' 2>/dev/null || true)"

  if [ -z "$vols" ] || [ "$vols" = "null" ]; then
    run "$KUBECTL -n \"$ns\" patch deploy \"$dep\" --type='json' -p='[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes\",\"value\":[{\"name\":\"$volname\",\"persistentVolumeClaim\":{\"claimName\":\"$pvc\"}}]}
    ]'"
  else
    run "$KUBECTL -n \"$ns\" patch deploy \"$dep\" --type='json' -p='[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"$volname\",\"persistentVolumeClaim\":{\"claimName\":\"$pvc\"}}}
    ]'"
  fi
}

# Add mount at DEST if missing
add_mount_if_missing() {
  local ns="$1" dep="$2" volname="$3"
  if $KUBECTL -n "$ns" get deploy "$dep" -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.mountPath}{"\n"}{end}' 2>/dev/null \
     | grep -qx "$DEST"; then
    return 0
  fi

  local mounts
  mounts="$($KUBECTL -n "$ns" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].volumeMounts}' 2>/dev/null || true)"

  if [ -z "$mounts" ] || [ "$mounts" = "null" ]; then
    run "$KUBECTL -n \"$ns\" patch deploy \"$dep\" --type='json' -p='[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts\",\"value\":[{\"name\":\"$volname\",\"mountPath\":\"$DEST\"}]}
    ]'"
  else
    run "$KUBECTL -n \"$ns\" patch deploy \"$dep\" --type='json' -p='[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"$volname\",\"mountPath\":\"$DEST\"}}
    ]'"
  fi
}

rollout_restart_wait() {
  local ns="$1" dep="$2"
  if [ "$DRY_RUN" = "1" ] || [ "$PREFLIGHT" = "1" ]; then
    echo "🧪 DRY: $KUBECTL -n $ns rollout restart deploy/$dep"
    echo "🧪 DRY: $KUBECTL -n $ns rollout status  deploy/$dep --timeout=300s"
    return 0
  fi
  $KUBECTL -n "$ns" rollout restart deploy/"$dep" >/dev/null
  $KUBECTL -n "$ns" rollout status deploy/"$dep" --timeout=300s
}

# -------- show current status --------
PERSISTED_IDX=()
UNPERSISTED_IDX=()

i=1
for d in "${DEPS[@]}"; do
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"

  if is_persisted "$NS" "$DEP"; then
    STATUS="✅ persisted"
    PERSISTED_IDX+=("$i")
  else
    STATUS="❌ NOT persisted"
    UNPERSISTED_IDX+=("$i")
  fi

  printf "[%d] %s / %s  →  %s\n" "$i" "$NS" "$DEP" "$STATUS"
  i=$((i+1))
done

echo
echo "Choose deployments to enable persistence:"
echo "  - all     (to enable ALL unpersisted)"
echo "  - 1,3,7   (comma-separated numbers)"
echo "  - Tip: run preflight only:  PREFLIGHT=1 $0"
echo "  - Tip: dry-run / audit:     DRY_RUN=1 $0"
read -r -p "👉 Selection: " SEL
SEL="$(echo "$SEL" | tr -d '[:space:]')"

TARGETS=()
if [ "$SEL" = "all" ] || [ "$SEL" = "ALL" ]; then
  TARGETS=("${UNPERSISTED_IDX[@]}")
else
  IFS=',' read -ra PARTS <<< "$SEL"
  for p in "${PARTS[@]}"; do
    n="$(echo "$p" | tr -d '[:space:]')"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "❌ Invalid selection: $n"; exit 1; }
    TARGETS+=("$n")
  done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "✅ Nothing to do (no unpersisted deployments selected)."
  exit 0
fi

echo
echo "🚀 Enabling persistence for selected deployments..."
echo

fixed=0; skipped=0; failed=0

for idx in "${TARGETS[@]}"; do
  d="${DEPS[$((idx-1))]}"
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"
  PVC="${DEP}-spa-pvc"

  echo "--------------------------------------------"
  echo "➡️  [$idx] $NS / $DEP"

  if is_persisted "$NS" "$DEP"; then
    echo "✅ Already persisted — skipping."
    skipped=$((skipped+1))
    continue
  fi

  # If deployment already has a mount at DEST, reuse its volume name; else use spa-pv
  VOLNAME="$(mount_volume_at_dest "$NS" "$DEP" || true)"
  if [ -z "$VOLNAME" ]; then
    VOLNAME="spa-pv"
  else
    echo "ℹ️  Existing mount uses volume: $VOLNAME"
  fi

  # Preflight validations
  if [ "$PREFLIGHT" = "1" ]; then
    if ! $KUBECTL -n "$NS" get deploy "$DEP" >/dev/null 2>&1; then
      echo "❌ PREFLIGHT: missing deployment $NS/$DEP"
      failed=$((failed+1))
      continue
    fi
  fi

  ensure_pvc "$NS" "$PVC"

  echo "🔧 Patching deployment with PVC volume + mount..."
  set +e
  add_volume_if_missing "$NS" "$DEP" "$VOLNAME" "$PVC"; rc1=$?
  add_mount_if_missing  "$NS" "$DEP" "$VOLNAME";        rc2=$?
  set -e

  if [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ]; then
    echo "❌ Patch failed for $NS/$DEP"
    failed=$((failed+1))
    continue
  fi

  rollout_restart_wait "$NS" "$DEP"

  if is_persisted "$NS" "$DEP"; then
    echo "✅ Enabled persistence: $NS / $DEP"
    fixed=$((fixed+1))
  else
    echo "❌ Still not detected as persisted."
    echo "   Check DEST is correct for this image."
    echo "   Try: DEST=/usr/share/nginx/html/openmrs/spa ./enable_persist_multi.sh"
    failed=$((failed+1))
  fi
done

echo
echo "✅ Done."
echo "   Fixed:   $fixed"
echo "   Skipped: $skipped"
echo "   Failed:  $failed"
