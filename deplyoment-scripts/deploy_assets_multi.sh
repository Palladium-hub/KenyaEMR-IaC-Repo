#!/usr/bin/env bash
set -euo pipefail

# Frontend (SPA)
SPA_ARCHIVE="/tmp/spa.tgz"
SPA_WORK="/tmp/spa_work"
SPA_DEST="/usr/share/nginx/html/openmrs/spa"
SPA_KEEP="openmrs-spa.env.json"

# Backend archives
CFG_ARCHIVE="/tmp/config.tgz"
MOD_ARCHIVE="/tmp/modules.tgz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENABLE_FRONTEND_PERSIST="$SCRIPT_DIR/enable_persist_multi.sh"
ENABLE_BACKEND_PERSIST="$SCRIPT_DIR/enable_backend_persist_multi.sh"

discover_frontends() {
  kubectl get deploy -A --no-headers |
    awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-frontend$/ {print $1"\t"$2}'
}

discover_backends() {
  kubectl get deploy -A --no-headers |
    awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-backend$/ {print $1"\t"$2}'
}

# IMPORTANT: print menus to STDERR so mapfile captures ONLY indices from STDOUT
select_indices() {
  local count="$1"
  local prompt="$2"

  >&2 echo
  >&2 echo "$prompt"
  >&2 echo "  - all     → ALL"
  >&2 echo "  - 1,3,7   → multi-select"
  read -p "👉 Selection: " SEL

  local -a out=()
  if [[ "$SEL" =~ ^[Aa][Ll][Ll]$ ]]; then
    for n in $(seq 1 "$count"); do out+=("$n"); done
  else
    IFS=',' read -ra PARTS <<< "$SEL"
    for p in "${PARTS[@]}"; do
      n="$(echo "$p" | tr -d '[:space:]')"
      [[ "$n" =~ ^[0-9]+$ ]] || { >&2 echo "❌ Invalid input: $n"; exit 1; }
      (( n>=1 && n<=count )) || { >&2 echo "❌ Out of range: $n"; exit 1; }
      out+=("$n")
    done
  fi

  # ONLY numbers go to stdout
  printf "%s\n" "${out[@]}"
}

frontend_is_persisted() {
  local ns="$1" dep="$2"
  kubectl get deploy -n "$ns" "$dep" -o json |
    jq -e ".spec.template.spec.containers[0].volumeMounts[]? |
           select(.mountPath==\"$SPA_DEST\")" >/dev/null 2>&1
}

backend_is_persisted() {
  local ns="$1" dep="$2"
  kubectl get deploy -n "$ns" "$dep" -o json |
    jq -e '.spec.template.spec.containers[0].volumeMounts[]? |
           select(.mountPath=="/openmrs/data" or .mountPath=="/data" or .mountPath=="/usr/share/openmrs/data" or .mountPath=="/var/lib/openmrs" or .mountPath=="/usr/local/tomcat/.OpenMRS")' \
    >/dev/null 2>&1
}

find_appdata_in_pod() {
  local ns="$1" pod="$2"
  kubectl -n "$ns" exec "$pod" -- sh -lc '
    for d in /openmrs/data /data /usr/share/openmrs/data /opt/openmrs/data /var/lib/openmrs /usr/local/tomcat/.OpenMRS ; do
      if [ -d "$d" ]; then
        if [ -d "$d/modules" ] || [ -d "$d/configuration" ]; then
          echo "$d"; exit 0
        fi
      fi
    done
    for d in /openmrs/data /data /usr/share/openmrs/data /opt/openmrs/data /var/lib/openmrs /usr/local/tomcat/.OpenMRS ; do
      [ -d "$d" ] && { echo "$d"; exit 0; }
    done
    exit 1
  '
}

deploy_spa_one() {
  local ns="$1" dep="$2"
  local pod
  pod="$(kubectl get pod -n "$ns" -l app="$dep" -o jsonpath='{.items[0].metadata.name}')"
  echo "   🌐 Frontend pod: $pod"

  kubectl exec -n "$ns" "$pod" -- sh -c "
    set -e
    cd '$SPA_DEST'
    find . -mindepth 1 -maxdepth 1 ! -name '$SPA_KEEP' -exec rm -rf {} +
  "

  tar -cf - -C "$SPA_WORK" . | \
    kubectl exec -i -n "$ns" "$pod" -- sh -c "cd '$SPA_DEST' && tar -xf -"

  echo "✅ SPA deployed: $ns / $dep"
}

# Backend deploy WITHOUT kubectl cp (because backend container has no tar)
deploy_backend_archive_one() {
  local ns="$1" backend_dep="$2" archive_path="$3" kind="$4" # kind=configuration|modules

  local pod appdata
  pod="$(kubectl get pod -n "$ns" -l app="$backend_dep" -o jsonpath='{.items[0].metadata.name}')"
  echo "   🧩 Backend pod: $pod"

  appdata="$(find_appdata_in_pod "$ns" "$pod")" || {
    echo "❌ Could not determine OpenMRS app data directory inside pod."
    exit 1
  }
  echo "   📁 OpenMRS data dir: $appdata"

  echo "   📤 Uploading ${kind}.tgz into pod via stdin (no tar needed)..."
  cat "$archive_path" | kubectl exec -i -n "$ns" "$pod" -- sh -lc "
python - <<'PY'
import sys, os, tarfile, shutil

kind = ''
appdata = ''
dest = os.path.join(appdata, kind)
tgz = '/tmp/%s.tgz' % kind

# write stdin to /tmp/<kind>.tgz
buf = sys.stdin.read()
f = open(tgz, 'wb')
f.write(buf)
f.close()

if not os.path.isdir(dest):
    os.makedirs(dest)

# wipe existing content in dest (keep folder)
for name in os.listdir(dest):
    p = os.path.join(dest, name)
    if os.path.isdir(p):
        shutil.rmtree(p)
    else:
        os.remove(p)

# extract .tgz into dest

t = tarfile.open(tgz, 'r:gz')
t.extractall(dest)
t.close()

# remove checksums if configuration
if kind == 'configuration':
    cs = os.path.join(appdata, 'configuration_checksums')
    if os.path.isdir(cs):
        shutil.rmtree(cs)

sys.stdout.write("OK extracted %s -> %s\n" % (tgz, dest))
PY
"

  echo "✅ Deployed ${kind}: $ns / $backend_dep"
  echo "🔄 Restarting backend to pick changes..."
  kubectl rollout restart deployment "$backend_dep" -n "$ns"
  kubectl rollout status deployment "$backend_dep" -n "$ns"
}

echo "What do you want to deploy?"
echo "  [1] SPA (frontend)          from $SPA_ARCHIVE"
echo "  [2] configuration (backend) from $CFG_ARCHIVE"
echo "  [3] modules (backend)       from $MOD_ARCHIVE"
echo "  [4] all"
read -p "👉 Selection (e.g. 1,3 or 4): " WHAT

DO_SPA="no"; DO_CFG="no"; DO_MOD="no"
if [[ "$WHAT" == "4" ]]; then
  DO_SPA="yes"; DO_CFG="yes"; DO_MOD="yes"
else
  IFS=',' read -ra PARTS <<< "$WHAT"
  for p in "${PARTS[@]}"; do
    x="$(echo "$p" | tr -d '[:space:]')"
    case "$x" in
      1) DO_SPA="yes" ;;
      2) DO_CFG="yes" ;;
      3) DO_MOD="yes" ;;
      *) echo "❌ Invalid selection: $x"; exit 1 ;;
    esac
  done
fi

if [ "$DO_SPA" = "yes" ]; then
  [ -f "$SPA_ARCHIVE" ] || { echo "❌ Missing $SPA_ARCHIVE"; exit 1; }
  echo "📦 Extracting SPA archive..."
  rm -rf "$SPA_WORK"
  mkdir -p "$SPA_WORK"
  tar -xzf "$SPA_ARCHIVE" -C "$SPA_WORK"
fi
if [ "$DO_CFG" = "yes" ]; then
  [ -f "$CFG_ARCHIVE" ] || { echo "❌ Missing $CFG_ARCHIVE"; exit 1; }
  echo "📦 Ready: configuration archive found."
fi
if [ "$DO_MOD" = "yes" ]; then
  [ -f "$MOD_ARCHIVE" ] || { echo "❌ Missing $MOD_ARCHIVE"; exit 1; }
  echo "📦 Ready: modules archive found."
fi

echo
echo "🚀 Deploying selected assets..."
echo

# SPA
if [ "$DO_SPA" = "yes" ]; then
  mapfile -t TARGET_DEPS < <(discover_frontends)
  [ ${#TARGET_DEPS[@]} -gt 0 ] || { echo "❌ No frontend deployments found."; exit 1; }

  echo "🔍 Discovering KenyaEMR tenant frontend deployments..."
  echo
  i=1
  for d in "${TARGET_DEPS[@]}"; do
    NS="$(echo "$d" | awk '{print $1}')"
    DEP="$(echo "$d" | awk '{print $2}')"
    if frontend_is_persisted "$NS" "$DEP"; then S="✅ persisted"; else S="⚠️  NOT persisted"; fi
    printf "[%d] %s / %s  →  %s\n" "$i" "$NS" "$DEP" "$S"
    i=$((i+1))
  done

  mapfile -t IDX < <(select_indices "${#TARGET_DEPS[@]}" "Choose tenants to deploy SPA to:")
  echo
  for idx in "${IDX[@]}"; do
    [[ -n "$idx" ]] || { echo "❌ Empty selection entry detected; aborting."; exit 1; }
    d="${TARGET_DEPS[$((idx-1))]}"
    NS="$(echo "$d" | awk '{print $1}')"
    DEP="$(echo "$d" | awk '{print $2}')"

    echo "--------------------------------------------"
    echo "➡️  [$idx] $NS / $DEP"

    if ! frontend_is_persisted "$NS" "$DEP"; then
      echo "⚠️  NOTE: This frontend is NOT persisted (may revert after restart)."
      if [ -x "$ENABLE_FRONTEND_PERSIST" ]; then
        read -p "❓ Enable frontend persistence now? [y/N]: " YN
        if [[ "$YN" =~ ^[Yy]$ ]]; then
          "$ENABLE_FRONTEND_PERSIST"
        fi
      fi
    fi

    deploy_spa_one "$NS" "$DEP"
  done
fi

# Backend
if [ "$DO_CFG" = "yes" ] || [ "$DO_MOD" = "yes" ]; then
  mapfile -t BACK_DEPS < <(discover_backends)
  [ ${#BACK_DEPS[@]} -gt 0 ] || { echo "❌ No backend deployments found."; exit 1; }

  echo
  echo "🔍 Discovering KenyaEMR tenant backend deployments..."
  echo
  i=1
  for d in "${BACK_DEPS[@]}"; do
    NS="$(echo "$d" | awk '{print $1}')"
    DEP="$(echo "$d" | awk '{print $2}')"
    if backend_is_persisted "$NS" "$DEP"; then S="✅ persisted"; else S="⚠️  NOT persisted"; fi
    printf "[%d] %s / %s  →  %s\n" "$i" "$NS" "$DEP" "$S"
    i=$((i+1))
  done

  mapfile -t IDX2 < <(select_indices "${#BACK_DEPS[@]}" "Choose tenants to deploy backend assets to:")
  echo
  for idx in "${IDX2[@]}"; do
    [[ -n "$idx" ]] || { echo "❌ Empty selection entry detected; aborting."; exit 1; }

    d="${BACK_DEPS[$((idx-1))]}"
    NS="$(echo "$d" | awk '{print $1}')"
    BDEP="$(echo "$d" | awk '{print $2}')"

    echo "--------------------------------------------"
    echo "➡️  [$idx] $NS / $BDEP"

    if ! backend_is_persisted "$NS" "$BDEP"; then
      echo "⚠️  NOTE: Backend data is NOT persisted (may revert after restart)."
      if [ -x "$ENABLE_BACKEND_PERSIST" ]; then
        read -p "❓ Enable backend persistence for THIS tenant now? [y/N]: " YN
        if [[ "$YN" =~ ^[Yy]$ ]]; then
          "$ENABLE_BACKEND_PERSIST" --ns "$NS" --dep "$BDEP"
        fi
      fi
      echo "ℹ️  Continuing..."
    fi

    if [ "$DO_CFG" = "yes" ]; then
      deploy_backend_archive_one "$NS" "$BDEP" "$CFG_ARCHIVE" "configuration"
    fi
    if [ "$DO_MOD" = "yes" ]; then
      deploy_backend_archive_one "$NS" "$BDEP" "$MOD_ARCHIVE" "modules"
    fi
  done
fi

echo
echo "🎉 Done."
echo "Frontend: hard refresh browser (Ctrl+Shift+R)."
echo "Backend: restarted where needed."
