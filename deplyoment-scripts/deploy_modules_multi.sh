#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="/tmp/modules.tgz"
SEED_DIR="/openmrs/distribution/openmrs_modules"
RUNTIME_DIR="/openmrs/data/modules"
READY_TIMEOUT="${READY_TIMEOUT:-300s}"

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
echo "✅ Using kubectl: $KUBECTL"
# --------------------------------------------------

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing command: $1"; exit 1; }; }
need_cmd awk
need_cmd jq

echo
echo "📦 Ready check: $ARCHIVE"
ls -lh "$ARCHIVE" || { echo "❌ Missing $ARCHIVE. Upload modules.tgz to /tmp/modules.tgz first."; exit 1; }
echo

echo "🔍 Discovering KenyaEMR tenant backend deployments..."
mapfile -t DEPS < <(
  # shellcheck disable=SC2086
  $KUBECTL get deploy -A --no-headers |
  awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-backend$/ {print $1"\t"$2}'
)

if [ ${#DEPS[@]} -eq 0 ]; then
  echo "❌ No backend deployments found (kenyaemr-tenant-* / *-backend)."
  exit 1
fi

i=1
for d in "${DEPS[@]}"; do
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"
  printf "[%d] %s / %s\n" "$i" "$NS" "$DEP"
  i=$((i+1))
done

echo
echo "Choose tenants to deploy MODULES to:"
echo "  - all     -> ALL"
echo "  - 1,3,7   -> multi-select"
read -r -p "Selection: " SEL

TARGETS=()
if [[ "$SEL" =~ ^([Aa][Ll][Ll])$ ]]; then
  for n in $(seq 1 ${#DEPS[@]}); do TARGETS+=("$n"); done
else
  IFS=',' read -ra PARTS <<< "$SEL"
  for p in "${PARTS[@]}"; do
    n="$(echo "$p" | tr -d '[:space:]')"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "❌ Invalid input: $n"; exit 1; }
    TARGETS+=("$n")
  done
fi

# ---------------- pod helpers ----------------

get_newest_pod() {
  local ns="$1" dep="$2"
  # newest by creationTimestamp (last item after sort)
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get pod -l app="$dep" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true
}

pod_phase() {
  local ns="$1" pod="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

pod_ready() {
  local ns="$1" pod="$2"
  local ready
  # shellcheck disable=SC2086
  ready="$($KUBECTL -n "$ns" get pod "$pod" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null \
    | awk -F= '$1=="Ready"{print $2; exit}')"
  [ "$ready" = "True" ]
}

wait_for_ready_pod() {
  local ns="$1" dep="$2" timeout_secs="${3:-300}"
  local start now pod ph
  start="$(date +%s)"

  while true; do
    pod="$(get_newest_pod "$ns" "$dep")"
    [ -n "$pod" ] || { echo "❌ No pod found for $ns/$dep" >&2; return 1; }

    ph="$(pod_phase "$ns" "$pod")"
    if [ "$ph" = "Running" ] && pod_ready "$ns" "$pod"; then
      echo "$pod"
      return 0
    fi

    now="$(date +%s)"
    if [ $((now-start)) -ge "$timeout_secs" ]; then
      echo "❌ Timeout waiting for READY pod for $ns/$dep (last pod=$pod phase=$ph)" >&2
      return 1
    fi
    sleep 3
  done
}

debug_deploy() {
  local ns="$1" dep="$2"
  echo
  echo "================ DEBUG $ns/$dep ================"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o wide || true
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get rs -l app="$dep" -o wide || true
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get pod -l app="$dep" -o wide || true
  local pod; pod="$(get_newest_pod "$ns" "$dep")"
  if [ -n "$pod" ]; then
    echo
    echo "--- describe pod/$pod (tail) ---"
    # shellcheck disable=SC2086
    $KUBECTL -n "$ns" describe pod "$pod" | tail -n 120 || true
    echo
    echo "--- logs pod/$pod (tail) ---"
    # shellcheck disable=SC2086
    $KUBECTL -n "$ns" logs "$pod" --tail=200 || true
  fi
  echo "================================================"
  echo
}

# ---------------- deployment introspection ----------------

# Find which container mounts /openmrs/data/modules (do NOT assume name=backend)
get_modules_container_name() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    .spec.template.spec.containers[]
    | select((.volumeMounts // []) | any(.mountPath=="/openmrs/data/modules"))
    | .name
  ' | head -n1
}

# Find the volume name that backs /openmrs/data/modules in that container
get_data_volume_name() {
  local ns="$1" dep="$2" cname="$3"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r --arg cn "$cname" '
    .spec.template.spec.containers[]
    | select(.name==$cn)
    | .volumeMounts[]
    | select(.mountPath=="/openmrs/data/modules")
    | .name
  ' | head -n1
}

seed_mount_present() {
  local ns="$1" dep="$2" cname="$3"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -e --arg cn "$cname" '
      .spec.template.spec.containers[]
      | select(.name==$cn)
      | (.volumeMounts // [])
      | any(.mountPath=="/openmrs/distribution/openmrs_modules")
    ' >/dev/null 2>&1
}

cleaner_present() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -e '
      (.spec.template.spec.initContainers // [])
      | any(.name=="clean-openmrs-data")
    ' >/dev/null 2>&1
}

ensure_clean_initcontainer() {
  local ns="$1" dep="$2" vol="$3"
  if cleaner_present "$ns" "$dep"; then
    echo "✅ Cleaner initContainer already present: clean-openmrs-data"
    return 0
  fi

  echo "🧹 Adding cleaner initContainer (wipes runtime modules before start)..."
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
        - name: $vol
          mountPath: /openmrs/data
"
  echo "✅ Cleaner added."
}

ensure_seed_mount() {
  local ns="$1" dep="$2" cname="$3" vol="$4"

  if seed_mount_present "$ns" "$dep" "$cname"; then
    echo "✅ Seed mount already present: $SEED_DIR"
    return 0
  fi

  echo "🧩 Seed mount missing. Adding seed mount ($SEED_DIR) from PVC volume: $vol ..."
  # IMPORTANT: strategic merge merges lists by 'name' for containers/initContainers
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
        - name: $vol
          mountPath: /openmrs/distribution/openmrs_modules
          subPath: distribution/openmrs_modules
      containers:
      - name: $cname
        volumeMounts:
        - name: $vol
          mountPath: /openmrs/distribution/openmrs_modules
          subPath: distribution/openmrs_modules
"
  echo "✅ Seed mount added."
}

seed_writable_check() {
  local ns="$1" pod="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" exec -it "$pod" -- sh -lc '
set -e
d=/openmrs/distribution/openmrs_modules
t=$d/.write_test
mkdir -p "$d" 2>/dev/null || true
echo test > "$t" && rm -f "$t"
' >/dev/null
}

extract_modules_into_seed() {
  local ns="$1" pod="$2"

  echo "📤 Uploading archive into READY pod: $pod"
  cat "$ARCHIVE" | \
    # shellcheck disable=SC2086
    $KUBECTL -n "$ns" exec -i "$pod" -- sh -c "cat > /tmp/modules.tgz"

  echo "🧹 Cleaning seed dir + extracting into seed dir..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" exec -it "$pod" -- sh -lc '
set -e
dest="'"$SEED_DIR"'"
rm -f "$dest"/*.omod 2>/dev/null || true

python - <<PY
import os, tarfile
tgz="/tmp/modules.tgz"
dest="'"$SEED_DIR"'"
t=tarfile.open(tgz,"r:gz")
t.extractall(dest)
t.close()
count=len([f for f in os.listdir(dest) if f.endswith(".omod")])
print("OK extracted into seed:", dest)
print("OMOD count:", count)
PY
'
}

verify_runtime_duplicates() {
  local ns="$1" pod="$2"
  echo "🔎 Verifying runtime duplicates (should be 0)..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" exec -it "$pod" -- sh -lc '
set -e
cd "'"$RUNTIME_DIR"'"

python - <<PY
import os, re, collections
files=[f for f in os.listdir(".") if f.endswith(".omod")]
def base(n):
    m=re.match(r"^(.+?)-\d", n)
    return m.group(1) if m else n
c=collections.defaultdict(list)
for f in sorted(files):
    c[base(f)].append(f)
dups={k:v for k,v in c.items() if len(v)>1}
print("Total omods:", len(files))
print("Duplicate groups:", len(dups))
if dups:
    for k,v in sorted(dups.items()):
        print(k, "=>", v)
    raise SystemExit(2)
PY
'
}

echo
echo "🚀 Deploying MODULES..."
echo

for idx in "${TARGETS[@]}"; do
  d="${DEPS[$((idx-1))]}"
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"

  echo "--------------------------------------------"
  echo "Target: $NS / $DEP"

  # Identify correct container + PVC volume
  CNAME="$(get_modules_container_name "$NS" "$DEP")"
  if [ -z "$CNAME" ]; then
    echo "❌ Could not find container mounting /openmrs/data/modules in $NS/$DEP"
    debug_deploy "$NS" "$DEP"
    continue
  fi

  VOL="$(get_data_volume_name "$NS" "$DEP" "$CNAME")"
  if [ -z "$VOL" ]; then
    echo "❌ Could not detect volume name for /openmrs/data/modules (ns=$NS dep=$DEP container=$CNAME)"
    debug_deploy "$NS" "$DEP"
    continue
  fi

  echo "📦 Detected container: $CNAME"
  echo "📦 Detected volume:    $VOL"

  POD_BEFORE="$(get_newest_pod "$NS" "$DEP")"
  echo "Pod(before): ${POD_BEFORE:-<none>}"

  # 1) Ensure seed mount + cleaner exist
  ensure_seed_mount "$NS" "$DEP" "$CNAME" "$VOL"
  ensure_clean_initcontainer "$NS" "$DEP" "$VOL"

  # 2) Restart so initContainers run (clean + seed ready)
  echo "🔄 Restarting backend to apply patches..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$NS" rollout restart deploy/"$DEP" >/dev/null || true
  # shellcheck disable=SC2086
  $KUBECTL -n "$NS" rollout status deploy/"$DEP" --timeout="$READY_TIMEOUT" >/dev/null || {
    echo "❌ Rollout failed for $NS/$DEP"
    debug_deploy "$NS" "$DEP"
    continue
  }

  POD="$(wait_for_ready_pod "$NS" "$DEP" 300)" || {
    echo "❌ No READY pod after patch for $NS/$DEP"
    debug_deploy "$NS" "$DEP"
    continue
  }
  echo "✅ Ready pod(after patch): $POD"

  # 3) Check seed writable
  if ! seed_writable_check "$NS" "$POD"; then
    echo "❌ Seed dir not writable in READY pod. (ns=$NS pod=$POD)"
    debug_deploy "$NS" "$DEP"
    continue
  fi

  # 4) Extract modules into seed dir
  extract_modules_into_seed "$NS" "$POD"

  # 5) Restart again: OpenMRS will re-seed runtime from updated seed
  echo "🔄 Restarting backend so runtime modules are re-seeded from updated seed..."
  # shellcheck disable=SC2086
  $KUBECTL -n "$NS" rollout restart deploy/"$DEP" >/dev/null || true
  # shellcheck disable=SC2086
  $KUBECTL -n "$NS" rollout status deploy/"$DEP" --timeout="$READY_TIMEOUT" >/dev/null || {
    echo "❌ Rollout failed after deploy for $NS/$DEP"
    debug_deploy "$NS" "$DEP"
    continue
  }

  POD2="$(wait_for_ready_pod "$NS" "$DEP" 300)" || {
    echo "❌ No READY pod after deploy for $NS/$DEP"
    debug_deploy "$NS" "$DEP"
    continue
  }
  echo "✅ Ready pod(after deploy): $POD2"

  # 6) Verify duplicates
  if verify_runtime_duplicates "$NS" "$POD2"; then
    echo "✅ Done: $NS / $DEP"
  else
    echo "❌ Duplicates still detected for $NS/$DEP."
    echo "   Verify cleaner initContainer exists and runs:"
    echo "     $KUBECTL -n $NS get deploy $DEP -o json | jq '.spec.template.spec.initContainers'"
    debug_deploy "$NS" "$DEP"
    continue
  fi
done

echo
echo "🎉 MODULES deployment finished."
echo "Tip: If OpenMRS shows module/liquibase errors, check:"
echo "  kubectl logs -n <ns> deploy/<backend> --tail=300 | egrep -i 'ModuleException|liquibase|Failed to start module|ERROR|WARN'"
