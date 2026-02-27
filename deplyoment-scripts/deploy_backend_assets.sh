#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# CONFIG: adjust if needed
# ---------------------------
DATA_DIR="/openmrs/data"
DEFAULT_CFG_DIR="configuration"      # in your local repo
DEFAULT_OMOD_DIR="modules"           # local folder containing .omod files (optional)
DEFAULT_PVC_SC="microk8s-hostpath"
DEFAULT_PVC_SIZE="2Gi"
BACKEND_MOUNT_PATH="/openmrs/data"   # where to persist

# ---------------------------
# Helpers
# ---------------------------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*"; }
err()  { printf "❌ %s\n" "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

# tar-stream copy (fast, works everywhere)
tar_copy_dir() {
  local src_dir="$1"
  local ns="$2"
  local pod="$3"
  local dest_dir="$4"

  if [[ ! -d "$src_dir" ]]; then
    err "Local dir not found: $src_dir"
    return 1
  fi

  # Ensure dest exists
  kubectl -n "$ns" exec "$pod" -- bash -lc "mkdir -p '$dest_dir'"

  # Copy content
  tar -C "$src_dir" -cf - . | kubectl -n "$ns" exec -i "$pod" -- tar -C "$dest_dir" -xf -
}

tar_copy_files_glob() {
  local src_glob_dir="$1"   # directory
  local pattern="$2"        # e.g. "*.omod"
  local ns="$3"
  local pod="$4"
  local dest_dir="$5"

  shopt -s nullglob
  local files=( "$src_glob_dir"/$pattern )
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    err "No files match $pattern in $src_glob_dir"
    return 1
  fi

  kubectl -n "$ns" exec "$pod" -- bash -lc "mkdir -p '$dest_dir'"

  # Stream files only
  tar -C "$src_glob_dir" -cf - $pattern | kubectl -n "$ns" exec -i "$pod" -- tar -C "$dest_dir" -xf -
}

get_backend_deployments() {
  # Prints: ns|deploy|tenant
  kubectl get deploy -A -o json \
  | jq -r '
      .items[]
      | select(.metadata.name | test("-backend$"))
      | (.metadata.namespace + "|" + .metadata.name + "|" + (.metadata.name | sub("-backend$"; "")))
    ' | sort
}

select_from_list() {
  local -n _items=$1
  local prompt="$2"

  echo
  echo "$prompt"
  echo "  - all     → select ALL"
  echo "  - 1,3,7   → comma-separated numbers"
  printf "👉 Selection: "
  read -r sel

  if [[ "$sel" == "all" ]]; then
    echo "ALL"
    return 0
  fi

  # Validate format
  if ! [[ "$sel" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    err "Invalid selection format."
    exit 1
  fi
  echo "$sel"
}

enable_backend_persistence() {
  local ns="$1"
  local deploy="$2"
  local tenant="$3"

  local pvc="${tenant}-openmrs-data-pvc"

  # Create PVC if missing
  if ! kubectl -n "$ns" get pvc "$pvc" >/dev/null 2>&1; then
    cat <<EOF | kubectl apply -n "$ns" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $DEFAULT_PVC_SC
  resources:
    requests:
      storage: $DEFAULT_PVC_SIZE
EOF
    ok "PVC created: $ns/$pvc"
  else
    ok "PVC exists: $ns/$pvc"
  fi

  # Check if mount already present
  local has_mount
  has_mount="$(kubectl -n "$ns" get deploy "$deploy" -o json | jq -r '
    (.spec.template.spec.containers[0].volumeMounts // [])
    | any(.mountPath=="'"$BACKEND_MOUNT_PATH"'")
  ')"

  if [[ "$has_mount" == "true" ]]; then
    ok "Persistence already enabled for $ns/$deploy (mount: $BACKEND_MOUNT_PATH)"
    return 0
  fi

  # Ensure arrays exist
  kubectl -n "$ns" patch deploy "$deploy" --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/volumes","value":[]},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[]}
  ]' 2>/dev/null || true

  # Add volume + mount
  kubectl -n "$ns" patch deploy "$deploy" --type='json' -p="[
    {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"openmrs-data\",\"persistentVolumeClaim\":{\"claimName\":\"$pvc\"}}},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"openmrs-data\",\"mountPath\":\"$BACKEND_MOUNT_PATH\"}}
  ]"

  ok "Persistence enabled: $ns/$deploy (PVC: $pvc → $BACKEND_MOUNT_PATH)"
}

restart_backend() {
  local ns="$1"
  local deploy="$2"
  kubectl -n "$ns" rollout restart deploy "$deploy" >/dev/null
  kubectl -n "$ns" rollout status deploy "$deploy" --timeout=300s
  ok "Restarted: $ns/$deploy"
}

get_pod_for_deploy() {
  local ns="$1"
  local tenant="$2"
  kubectl -n "$ns" get pod -l "app=${tenant}-backend" -o jsonpath='{.items[0].metadata.name}'
}

# ---------------------------
# Main
# ---------------------------
need_cmd kubectl
need_cmd jq
need_cmd tar

bold "🔍 Discovering tenant backend deployments..."
mapfile -t DEPLOY_LINES < <(get_backend_deployments)

if (( ${#DEPLOY_LINES[@]} == 0 )); then
  err "No *-backend deployments found."
  exit 1
fi

declare -a MENU
i=1
for line in "${DEPLOY_LINES[@]}"; do
  IFS='|' read -r ns deploy tenant <<<"$line"
  MENU+=("$ns|$deploy|$tenant")
  printf "[%d] %s / %s\n" "$i" "$ns" "$deploy"
  ((i++))
done

SEL="$(select_from_list MENU "Choose tenants to deploy backend assets to:")"

echo
bold "What do you want to upload?"
echo "  1) configuration (Initializer config folder)"
echo "  2) modules (.omod files)"
echo "  3) both (configuration + modules)"
printf "👉 Selection (1/2/3): "
read -r WHAT

if [[ "$WHAT" != "1" && "$WHAT" != "2" && "$WHAT" != "3" ]]; then
  err "Invalid choice."
  exit 1
fi

echo
printf "Local repo root (where '$DEFAULT_CFG_DIR/' lives) [default: current dir]: "
read -r REPO_ROOT
REPO_ROOT="${REPO_ROOT:-$(pwd)}"

CFG_SRC="$REPO_ROOT/$DEFAULT_CFG_DIR"
OMOD_SRC="$REPO_ROOT/$DEFAULT_OMOD_DIR"

echo
printf "Delete configuration_checksums before upload? (recommended) [Y/n]: "
read -r DELCHK
DELCHK="${DELCHK:-Y}"

echo
printf "Enable backend persistence (/openmrs/data on PVC) before upload? [Y/n]: "
read -r PERSIST
PERSIST="${PERSIST:-Y}"

# Build selected indexes
declare -a IDX=()
if [[ "$SEL" == "ALL" ]]; then
  for n in $(seq 1 ${#MENU[@]}); do IDX+=("$n"); done
else
  IFS=',' read -r -a IDX <<<"$SEL"
fi

echo
bold "🚀 Starting deployment..."

for n in "${IDX[@]}"; do
  entry="${MENU[$((n-1))]}"
  IFS='|' read -r ns deploy tenant <<<"$entry"

  echo
  bold "➡️  $ns / $deploy"

  if [[ "$PERSIST" =~ ^[Yy]$ ]]; then
    enable_backend_persistence "$ns" "$deploy" "$tenant"
  else
    warn "Persistence skipped for $ns/$deploy"
  fi

  pod="$(get_pod_for_deploy "$ns" "$tenant")"
  ok "Target pod: $pod"

  if [[ "$DELCHK" =~ ^[Yy]$ ]]; then
    kubectl -n "$ns" exec "$pod" -- bash -lc "rm -rf '$DATA_DIR/configuration_checksums'"
    ok "Deleted: $DATA_DIR/configuration_checksums"
  fi

  if [[ "$WHAT" == "1" || "$WHAT" == "3" ]]; then
    # Replace configuration completely (clean)
    kubectl -n "$ns" exec "$pod" -- bash -lc "rm -rf '$DATA_DIR/configuration' && mkdir -p '$DATA_DIR/configuration'"
    tar_copy_dir "$CFG_SRC" "$ns" "$pod" "$DATA_DIR/configuration"
    kubectl -n "$ns" exec "$pod" -- bash -lc "chown -R 1001:0 '$DATA_DIR/configuration' 2>/dev/null || true"
    ok "Uploaded configuration → $DATA_DIR/configuration"
  fi

  if [[ "$WHAT" == "2" || "$WHAT" == "3" ]]; then
    # Upload .omod files into /openmrs/data/modules
    kubectl -n "$ns" exec "$pod" -- bash -lc "mkdir -p '$DATA_DIR/modules'"
    tar_copy_files_glob "$OMOD_SRC" "*.omod" "$ns" "$pod" "$DATA_DIR/modules"
    kubectl -n "$ns" exec "$pod" -- bash -lc "chown -R 1001:0 '$DATA_DIR/modules' 2>/dev/null || true"
    ok "Uploaded modules (*.omod) → $DATA_DIR/modules"
  fi

  restart_backend "$ns" "$deploy"
done

echo
ok "Deployment finished."
echo "Tip: watch logs per tenant:"
echo "  kubectl -n <ns> logs -l app=<tenant>-backend -f | egrep -i 'initializer|configuration|checksum|error|warn'"
