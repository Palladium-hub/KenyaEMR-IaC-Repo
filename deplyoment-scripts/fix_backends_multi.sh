#!/usr/bin/env bash
set -euo pipefail

SEED_DIR="/openmrs/distribution/openmrs_modules"
PVC_SIZE="${PVC_SIZE:-5Gi}"

# ---------------- kubectl resolver ----------------
KUBECTL=""
for c in "kubectl" "microk8s kubectl" "/snap/microk8s/current/kubectl" "/usr/local/bin/kubectl" "/usr/bin/kubectl"; do
  if [[ "$c" == *" "* ]]; then
    if command -v ${c%% *} >/dev/null 2>&1; then KUBECTL="$c"; break; fi
  else
    if command -v "$c" >/dev/null 2>&1; then KUBECTL="$c"; break; fi
  fi
done
if [ -z "$KUBECTL" ]; then
  echo "❌ kubectl not found. Run on the node that has kubectl/microk8s."
  exit 1
fi
# --------------------------------------------------

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing command: $1"; exit 1; }; }
need_cmd awk
need_cmd jq

log() { echo "$@"; }

discover_backends() {
  # shellcheck disable=SC2086
  $KUBECTL get deploy -A --no-headers |
    awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-backend$/ {print $1"\t"$2}'
}

get_backend_image() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    .spec.template.spec.containers[] | select(.name=="backend") | .image // empty
  ' | head -n1
}

# Volume name that mounts /openmrs/data/modules (best), else /openmrs/data/configuration, else first PVC volume name
detect_data_volume_name() {
  local ns="$1" dep="$2"

  # 1) try volumeMount by mountPath
  # shellcheck disable=SC2086
  local v1="$($KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    .spec.template.spec.containers[]
    | select(.name=="backend")
    | (.volumeMounts // [])
    | map(select(.mountPath=="/openmrs/data/modules" or .mountPath=="/openmrs/data/configuration"))
    | .[0].name // empty
  ' | head -n1)"
  if [ -n "$v1" ]; then echo "$v1"; return 0; fi

  # 2) otherwise: first PVC volume name in spec.volumes
  # shellcheck disable=SC2086
  local v2="$($KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    (.spec.template.spec.volumes // [])
    | map(select(.persistentVolumeClaim?))
    | .[0].name // empty
  ' | head -n1)"
  echo "$v2"
}

has_pvc_volume() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -e '
    ((.spec.template.spec.volumes // []) | map(select(.persistentVolumeClaim?)) | length) > 0
  ' >/dev/null
}

ensure_pvc_exists() {
  local ns="$1" pvc="$2"
  # shellcheck disable=SC2086
  if $KUBECTL -n "$ns" get pvc "$pvc" >/dev/null 2>&1; then
    log "   ✅ PVC exists: $pvc"
    return 0
  fi

  log "   📦 Creating PVC: $pvc (${PVC_SIZE})"
  # Create PVC (storageClass omitted -> default, works on microk8s hostpath setups)
  cat <<YAML | $KUBECTL -n "$ns" apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
YAML
  log "   ✅ PVC created: $pvc"
}

enable_backend_persistence_if_missing() {
  local ns="$1" dep="$2"

  if has_pvc_volume "$ns" "$dep"; then
    log "   ✅ Backend already has PVC volume (persisted)"
    return 0
  fi

  local pvc="${dep}-data-pvc"
  ensure_pvc_exists "$ns" "$pvc"

  log "   🧩 Enabling backend persistence (add PVC volume + /openmrs/data subPath mounts)..."
  # Add volume "data-pv" + the standard subPath mounts used by the chart
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" patch deploy "$dep" --type='strategic' -p "
spec:
  template:
    spec:
      volumes:
      - name: data-pv
        persistentVolumeClaim:
          claimName: ${pvc}
      containers:
      - name: backend
        volumeMounts:
        - name: data-pv
          mountPath: /openmrs/data/modules
          subPath: modules
        - name: data-pv
          mountPath: /openmrs/data/configuration
          subPath: configuration
        - name: data-pv
          mountPath: /openmrs/data/configuration_checksums
          subPath: configuration_checksums
" >/dev/null

  log "   ✅ Persistence patch applied"
}

has_initcontainer() {
  local ns="$1" dep="$2" name="$3"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -e --arg n "$name" '
    ((.spec.template.spec.initContainers // []) | map(select(.name==$n)) | length) > 0
  ' >/dev/null
}

has_seed_mount() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -e '
    .spec.template.spec.containers[]
    | select(.name=="backend")
    | (.volumeMounts // [])
    | map(select(.mountPath=="/openmrs/distribution/openmrs_modules"))
    | length > 0
  ' >/dev/null
}

patch_seed_mount_and_init() {
  local ns="$1" dep="$2" vol="$3"
  log "   🧩 Adding seed mount + init-seed-openmrs-modules (PVC-backed, writable)..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" patch deploy "$dep" --type='strategic' -p "
spec:
  template:
    spec:
      initContainers:
      - name: init-seed-openmrs-modules
        image: busybox:1.36
        imagePullPolicy: IfNotPresent
        command: ['sh','-c']
        args:
          - >
            set -e;
            mkdir -p /openmrs/distribution/openmrs_modules;
            chmod -R 0777 /openmrs/distribution || true;
            echo 'seed dir ready';
        volumeMounts:
        - name: ${vol}
          mountPath: /openmrs/distribution/openmrs_modules
          subPath: distribution/openmrs_modules
      containers:
      - name: backend
        volumeMounts:
        - name: ${vol}
          mountPath: /openmrs/distribution/openmrs_modules
          subPath: distribution/openmrs_modules
" >/dev/null
}

patch_cleaner() {
  local ns="$1" dep="$2" vol="$3"
  log "   🧹 Adding clean-openmrs-data initContainer (prevents duplicates after restart)..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" patch deploy "$dep" --type='strategic' -p "
spec:
  template:
    spec:
      initContainers:
      - name: clean-openmrs-data
        image: busybox:1.36
        imagePullPolicy: IfNotPresent
        command: ['sh','-c']
        args:
          - >
            set -e;
            echo 'Cleaning runtime modules + configuration_checksums';
            rm -f /openmrs/data/modules/*.omod || true;
            rm -rf /openmrs/data/configuration_checksums || true;
            echo 'Done';
        volumeMounts:
        - name: ${vol}
          mountPath: /openmrs/data
" >/dev/null
}

restart_dep() {
  local ns="$1" dep="$2"
  log "   🔄 Restarting $ns/$dep ..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" rollout restart deploy/"$dep" >/dev/null
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" rollout status deploy/"$dep" --timeout=300s >/dev/null
  log "   ✅ Restart complete"
}

main() {
  log "🔍 Discovering KenyaEMR tenant backend deployments..."
  mapfile -t DEPS < <(discover_backends)

  if [ ${#DEPS[@]} -eq 0 ]; then
    log "❌ No kenyaemr-tenant-*/*-backend deployments found."
    exit 1
  fi

  log ""
  log "🚀 Applying fixes across ${#DEPS[@]} backends..."
  log ""

  local fixed=0 skipped=0 failed=0

  for row in "${DEPS[@]}"; do
    local ns dep
    ns="$(echo "$row" | awk '{print $1}')"
    dep="$(echo "$row" | awk '{print $2}')"

    log "--------------------------------------------"
    log "Target: $ns / $dep"

    # Ensure persistence first (this is why chu/hgua/jfk were failing)
    enable_backend_persistence_if_missing "$ns" "$dep"

    # Now we can detect the volume reliably
    local vol
    vol="$(detect_data_volume_name "$ns" "$dep")"
    if [ -z "$vol" ]; then
      log "   ❌ Still cannot detect a data volume name after enabling persistence. Skipping."
      failed=$((failed+1))
      continue
    fi
    log "   📦 Using volume: $vol"

    local need_restart=0

    if has_seed_mount "$ns" "$dep"; then
      log "   ✅ Seed mount already present: $SEED_DIR"
    else
      patch_seed_mount_and_init "$ns" "$dep" "$vol"
      need_restart=1
    fi

    if has_initcontainer "$ns" "$dep" "clean-openmrs-data"; then
      log "   ✅ Cleaner already present: clean-openmrs-data"
    else
      patch_cleaner "$ns" "$dep" "$vol"
      need_restart=1
    fi

    if [ "$need_restart" -eq 1 ]; then
      restart_dep "$ns" "$dep"
      fixed=$((fixed+1))
    else
      log "   ➖ Nothing to change"
      skipped=$((skipped+1))
    fi
  done

  log ""
  log "✅ Finished."
  log "   Fixed:   $fixed"
  log "   Skipped: $skipped"
  log "   Failed:  $failed"
  log ""
  log "Next: run deploy_modules_multi.sh / deploy_config_multi.sh"
}

main
