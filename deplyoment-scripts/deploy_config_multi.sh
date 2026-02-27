#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="/tmp/config.tgz"
RUNTIME_CFG_DIR="/openmrs/data/configuration"

# --- modes ---
PREFLIGHT=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --preflight) PREFLIGHT=true ;;
    --dry-run|--audit) DRY_RUN=true ;;
  esac
done

# ---------------- kubectl resolver ----------------
KUBECTL=""
for c in "kubectl" "microk8s kubectl" "/snap/microk8s/current/kubectl" "/usr/local/bin/kubectl" "/usr/bin/kubectl"; do
  if [[ "$c" == *" "* ]]; then
    # shellcheck disable=SC2086
    if command -v ${c%% *} >/dev/null 2>&1; then KUBECTL="$c"; break; fi
  else
    if command -v "$c" >/dev/null 2>&1; then KUBECTL="$c"; break; fi
  fi
done
if [ -z "$KUBECTL" ]; then
  echo "❌ kubectl not found. Run this script on the node that has kubectl/microk8s."
  exit 1
fi
# --------------------------------------------------

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing command: $1"; exit 1; }; }
need_cmd awk
need_cmd jq

echo "Ready check: $ARCHIVE"
ls -lh "$ARCHIVE" || { echo "❌ Missing $ARCHIVE. Upload config.tgz to /tmp/config.tgz first."; exit 1; }
echo

echo "Discovering KenyaEMR tenant backend deployments..."
mapfile -t DEP_ROWS < <(
  # shellcheck disable=SC2086
  $KUBECTL get deploy -A --no-headers \
    | awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-backend$/ {print $1"\t"$2}'
)

if [ ${#DEP_ROWS[@]} -eq 0 ]; then
  echo "❌ No backend deployments found (kenyaemr-tenant-* / *-backend)."
  exit 1
fi

i=1
for row in "${DEP_ROWS[@]}"; do
  NS="$(awk '{print $1}' <<<"$row")"
  DEP="$(awk '{print $2}' <<<"$row")"
  printf "[%d] %s / %s\n" "$i" "$NS" "$DEP"
  i=$((i+1))
done

echo
echo "Choose tenants to deploy CONFIGURATION to:"
echo "  - all     -> ALL"
echo "  - 1,3,7   -> multi-select"
read -r -p "Selection: " SEL

TARGETS=()
SEL="$(echo "$SEL" | tr -d '[:space:]')"
if [[ "$SEL" =~ ^([Aa][Ll][Ll])$ ]]; then
  for n in $(seq 1 ${#DEP_ROWS[@]}); do TARGETS+=("$n"); done
else
  IFS=',' read -ra PARTS <<< "$SEL"
  for p in "${PARTS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || { echo "❌ Invalid input: $p"; exit 1; }
    if (( p < 1 || p > ${#DEP_ROWS[@]} )); then
      echo "❌ Selection out of range: $p (valid: 1..${#DEP_ROWS[@]})"
      exit 1
    fi
    TARGETS+=("$p")
  done
fi

# ---- helpers ----

get_deploy_json() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json
}

get_pod_by_app_label() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get pod -l "app=$dep" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

get_selector_label_selector() {
  # returns like: key1=value1,key2=value2
  jq -r '
    .spec.selector.matchLabels
    | to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  '
}

get_pod_from_deploy_selector() {
  local ns="$1" dep="$2"
  local sel
  sel="$(get_deploy_json "$ns" "$dep" | get_selector_label_selector)"
  [ -n "$sel" ] || { echo ""; return 0; }
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get pod -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

wait_ready() {
  local ns="$1" pod="$2"
  echo "⏳ Waiting for pod to be Ready..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null
}

# Detect seed config directory (image standard is /openmrs/distribution/openmrs_config)
detect_seed_config_dir() {
  local ns="$1" pod="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" exec -i "$pod" -- sh -lc '
for d in /openmrs/distribution/openmrs_config /openmrs/distribution/openmrs_config/*; do
  [ -d "$d" ] && { echo "/openmrs/distribution/openmrs_config"; exit 0; }
done
echo ""
' 2>/dev/null | tr -d '\r' | head -n1
}

upload_archive() {
  local ns="$1" pod="$2"
  echo "Copying archive into pod (stream stdin)..."
  cat "$ARCHIVE" | \
    # shellcheck disable=SC2086
    $KUBECTL -n "$ns" exec -i "$pod" -- sh -c "cat > /tmp/config.tgz"
}

extract_runtime_config() {
  local ns="$1" pod="$2"
  echo "Cleaning runtime config dir + removing checksums + extracting..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" exec -it "$pod" -- sh -lc '
set -e
dest="'"$RUNTIME_CFG_DIR"'"
mkdir -p "$dest"
rm -rf /openmrs/data/configuration_checksums || true
rm -rf "$dest"/* || true

python - <<PY
import tarfile
tgz="/tmp/config.tgz"
dest="'"$RUNTIME_CFG_DIR"'"
t=tarfile.open(tgz,"r:gz")
t.extractall(dest)
t.close()
print("OK extracted to", dest)
PY
'
}

restart_deploy() {
  local ns="$1" dep="$2"
  echo "Restarting backend to load new configuration..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" rollout restart deploy/"$dep" >/dev/null
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" rollout status deploy/"$dep" --timeout=300s >/dev/null
}

# Main loop
echo
echo "Deploying CONFIGURATION..."
echo

for idx in "${TARGETS[@]}"; do
  row="${DEP_ROWS[$((idx-1))]}"
  NS="$(awk '{print $1}' <<<"$row")"
  DEP="$(awk '{print $2}' <<<"$row")"

  echo "--------------------------------------------"
  echo "Target: [$idx] $NS / $DEP"

  # ensure deploy exists
  if ! $KUBECTL -n "$NS" get deploy "$DEP" >/dev/null 2>&1; then
    echo "❌ Deployment not found: $NS/$DEP"
    continue
  fi

  POD="$(get_pod_by_app_label "$NS" "$DEP")"
  if [ -z "$POD" ]; then
    POD="$(get_pod_from_deploy_selector "$NS" "$DEP")"
  fi
  if [ -z "$POD" ]; then
    echo "❌ Could not find a pod for $NS/$DEP (no pods match app=$DEP and selector labels)."
    continue
  fi

  echo "Backend pod: $POD"
  wait_ready "$NS" "$POD"

  SEED_CFG="$(detect_seed_config_dir "$NS" "$POD")"
  echo "Detected seed config dir: ${SEED_CFG:-<none>}"

  if $PREFLIGHT; then
    echo "🧪 PREFLIGHT:"
    echo "  - Will upload: $ARCHIVE"
    echo "  - Will extract to runtime: $RUNTIME_CFG_DIR"
    echo "  - Will restart deployment: $NS/$DEP"
    echo "✅ Preflight complete for $NS/$DEP"
    continue
  fi

  if $DRY_RUN; then
    echo "📝 DRY-RUN / AUDIT:"
    echo "  Would upload archive to pod /tmp/config.tgz"
    echo "  Would wipe + extract into $RUNTIME_CFG_DIR"
    echo "  Would restart deploy/$DEP"
    continue
  fi

  upload_archive "$NS" "$POD"
  extract_runtime_config "$NS" "$POD"
  restart_deploy "$NS" "$DEP"

  echo "DONE: $NS / $DEP"
done

echo
echo "✅ CONFIGURATION deployment finished."
