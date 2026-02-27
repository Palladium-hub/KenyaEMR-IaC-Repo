#!/usr/bin/env bash
set -euo pipefail

# archives already uploaded to this server (/tmp)
SPA_ARCHIVE="/tmp/spa.tgz"
CFG_ARCHIVE="/tmp/config.tgz"
MOD_ARCHIVE="/tmp/modules.tgz"

WORK_BASE="/tmp/deploy-work"
SPA_WORK="$WORK_BASE/spa"
CFG_WORK="$WORK_BASE/config"
MOD_WORK="$WORK_BASE/modules"

SPA_DEST="/usr/share/nginx/html/openmrs/spa"
SPA_KEEP="openmrs-spa.env.json"

BACKEND_MOD_DEST="data/modules"
BACKEND_CFG_DEST="data/configuration"
BACKEND_CHK_DIR="data/configuration_checksums"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT_PERSIST="$SCRIPT_DIR/enable_persist_multi.sh"
BACK_PERSIST="$SCRIPT_DIR/enable_backend_persist_multi.sh"

need_spa=false
need_cfg=false
need_mod=false

echo "What do you want to deploy?"
echo "  [1] SPA (frontend)          from $SPA_ARCHIVE"
echo "  [2] configuration (backend) from $CFG_ARCHIVE"
echo "  [3] modules (backend)       from $MOD_ARCHIVE"
echo "  [4] all"
read -p "👉 Selection (e.g. 1,3 or 4): " SEL

SEL="$(echo "$SEL" | tr -d '[:space:]')"
if [ "$SEL" = "4" ] || [[ "$SEL" =~ ^[Aa][Ll][Ll]$ ]]; then
  need_spa=true; need_cfg=true; need_mod=true
else
  IFS=',' read -ra PARTS <<< "$SEL"
  for p in "${PARTS[@]}"; do
    case "$p" in
      1) need_spa=true ;;
      2) need_cfg=true ;;
      3) need_mod=true ;;
      *) echo "❌ Invalid option: $p"; exit 1 ;;
    esac
  done
fi

# sanity checks
if $need_spa && [ ! -f "$SPA_ARCHIVE" ]; then
  echo "❌ Missing $SPA_ARCHIVE. Upload spa.tgz first."
  exit 1
fi
if $need_cfg && [ ! -f "$CFG_ARCHIVE" ]; then
  echo "❌ Missing $CFG_ARCHIVE. Upload config.tgz first."
  exit 1
fi
if $need_mod && [ ! -f "$MOD_ARCHIVE" ]; then
  echo "❌ Missing $MOD_ARCHIVE. Upload modules.tgz first."
  exit 1
fi

mkdir -p "$WORK_BASE"

if $need_spa; then
  echo "📦 Extracting SPA archive..."
  rm -rf "$SPA_WORK"
  mkdir -p "$SPA_WORK"
  tar -xzf "$SPA_ARCHIVE" -C "$SPA_WORK"
fi

if $need_cfg; then
  echo "📦 Extracting configuration archive..."
  rm -rf "$CFG_WORK"
  mkdir -p "$CFG_WORK"
  tar -xzf "$CFG_ARCHIVE" -C "$CFG_WORK"
fi

if $need_mod; then
  echo "📦 Extracting modules archive..."
  rm -rf "$MOD_WORK"
  mkdir -p "$MOD_WORK"
  tar -xzf "$MOD_ARCHIVE" -C "$MOD_WORK"
fi

echo
echo "🔍 Discovering KenyaEMR tenant frontend deployments..."
mapfile -t DEPS < <(
  kubectl get deploy -A --no-headers |
  awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-frontend$/ {print $1"\t"$2}'
)

if [ ${#DEPS[@]} -eq 0 ]; then
  echo "❌ No frontend deployments found."
  exit 1
fi

declare -A FRONT_PERSISTED

echo
i=1
for d in "${DEPS[@]}"; do
  NS="$(echo "$d" | awk '{print $1}')"
  DEP="$(echo "$d" | awk '{print $2}')"

  if kubectl get deploy -n "$NS" "$DEP" -o json |
     jq -e ".spec.template.spec.containers[0].volumeMounts[]? |
            select(.mountPath==\"$SPA_DEST\")" >/dev/null 2>&1; then
    STATUS="✅ persisted"
    FRONT_PERSISTED["$i"]="yes"
  else
    STATUS="⚠️  NOT persisted"
    FRONT_PERSISTED["$i"]="no"
  fi

  printf "[%d] %s / %s  →  %s\n" "$i" "$NS" "$DEP" "$STATUS"
  i=$((i+1))
done

echo
echo "Choose tenants to deploy to:"
echo "  - all     → deploy to ALL"
echo "  - 1,3,7   → multi-select"
read -p "👉 Selection: " TARGET_SEL

TARGETS=()
if [[ "$TARGET_SEL" =~ ^[Aa][Ll][Ll]$ ]]; then
  for n in $(seq 1 ${#DEPS[@]}); do TARGETS+=("$n"); done
else
  IFS=',' read -ra PARTS <<< "$TARGET_SEL"
  for p in "${PARTS[@]}"; do
    n="$(echo "$p" | tr -d '[:space:]')"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "❌ Invalid input: $n"; exit 1; }
    TARGETS+=("$n")
  done
fi

echo
echo "🚀 Deploying selected assets..."
echo

for idx in "${TARGETS[@]}"; do
  d="${DEPS[$((idx-1))]}"
  NS="$(echo "$d" | awk '{print $1}')"
  FRONT_DEP="$(echo "$d" | awk '{print $2}')"
  BACK_DEP="${FRONT_DEP%-frontend}-backend"

  echo "--------------------------------------------"
  echo "➡️  [$idx] $NS / $FRONT_DEP"

  # ---------- SPA (frontend) ----------
  if $need_spa; then
    if [ "${FRONT_PERSISTED[$idx]}" = "no" ]; then
      echo "⚠️  NOTE: Frontend is NOT persisted."
      echo "    Update will work now, but may revert after pod restart."

      if [ -x "$FRONT_PERSIST" ]; then
        echo "    Persistence helper found: $FRONT_PERSIST"
        read -p "❓ Enable frontend persistence now? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
          echo "🔧 Enabling frontend persistence (non-interactive)..."
          "$FRONT_PERSIST" --ns "$NS" --dep "$FRONT_DEP"
        else
          echo "ℹ️  Continuing without frontend persistence."
        fi
      else
        echo "    ⚠️ Frontend persistence helper not found/executable: $FRONT_PERSIST"
        echo "ℹ️  Continuing without persistence."
      fi
    fi

    FRONT_POD="$(kubectl get pod -n "$NS" -l app="$FRONT_DEP" -o jsonpath='{.items[0].metadata.name}')"
    echo "   🌐 Frontend pod: $FRONT_POD"

    # wipe SPA (keep env json) then deploy
    kubectl exec -n "$NS" "$FRONT_POD" -- sh -c "
      set -e
      cd '$SPA_DEST'
      find . -mindepth 1 -maxdepth 1 ! -name '$SPA_KEEP' -exec rm -rf {} +
    "

    tar -cf - -C "$SPA_WORK" . | \
      kubectl exec -i -n "$NS" "$FRONT_POD" -- sh -c "cd '$SPA_DEST' && tar -xf -"

    echo "✅ SPA deployed: $NS / $FRONT_DEP"
  fi

  # ---------- configuration/modules (backend) ----------
  if $need_cfg || $need_mod; then
    echo "   🧠 Backend deployment: $BACK_DEP"

    # check backend exists
    if ! kubectl get deploy -n "$NS" "$BACK_DEP" >/dev/null 2>&1; then
      echo "⚠️  Backend deployment not found: $NS / $BACK_DEP"
      echo "    Skipping backend assets for this tenant."
      continue
    fi

    # detect backend persistence (modules+config)
    BACK_PERSISTED="no"
    if kubectl get deploy -n "$NS" "$BACK_DEP" -o json | jq -e \
      ".spec.template.spec.containers[0].volumeMounts[]? | select(.mountPath==\"$BACKEND_MOD_DEST\")" >/dev/null 2>&1 \
      && kubectl get deploy -n "$NS" "$BACK_DEP" -o json | jq -e \
      ".spec.template.spec.containers[0].volumeMounts[]? | select(.mountPath==\"$BACKEND_CFG_DEST\")" >/dev/null 2>&1; then
      BACK_PERSISTED="yes"
    fi

    if [ "$BACK_PERSISTED" = "no" ]; then
      echo "⚠️  NOTE: Backend modules/config are NOT persisted."
      echo "    Update will work now, but may revert after pod restart."

      if [ -x "$BACK_PERSIST" ]; then
        echo "    Persistence helper found: $BACK_PERSIST"
        read -p "❓ Enable backend persistence now? [y/N]: " CONFIRM2
        if [[ "$CONFIRM2" =~ ^[Yy]$ ]]; then
          echo "🔧 Enabling backend persistence (non-interactive)..."
          "$BACK_PERSIST" --ns "$NS" --dep "$BACK_DEP"
        else
          echo "ℹ️  Continuing without backend persistence."
        fi
      else
        echo "    ⚠️ Backend persistence helper not found/executable: $BACK_PERSIST"
        echo "ℹ️  Continuing without persistence."
      fi
    fi

    BACK_POD="$(kubectl get pod -n "$NS" -l app="$BACK_DEP" -o jsonpath='{.items[0].metadata.name}')"
    echo "   🧩 Backend pod: $BACK_POD"

    if $need_cfg; then
      echo "   ⚙️  Deploying configuration…"

      # remove config + checksums to avoid stale asset behavior
      kubectl exec -n "$NS" "$BACK_POD" -- sh -c "
        set -e
      
        # wipe existing config contents (keep dir)
        find '$BACKEND_CFG_DEST' -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
      "

      tar -cf - -C "$CFG_WORK" . | \
        kubectl exec -i -n "$NS" "$BACK_POD" -- sh -c "cd '$BACKEND_CFG_DEST' && tar -xf -"

      echo "   ✅ configuration deployed."
    fi

    if $need_mod; then
      echo "   🧱 Deploying modules…"

      kubectl exec -n "$NS" "$BACK_POD" -- sh -c "
        set -e
        mkdir -p '$BACKEND_MOD_DEST'
        # wipe existing modules contents (keep dir)
        find '$BACKEND_MOD_DEST' -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
      "

      tar -cf - -C "$MOD_WORK" . | \
        kubectl exec -i -n "$NS" "$BACK_POD" -- sh -c "cd '$BACKEND_MOD_DEST' && tar -xf -"

      echo "   ✅ modules deployed."
    fi

    echo "   🔄 Restarting backend to load new modules/config..."
    kubectl rollout restart deployment "$BACK_DEP" -n "$NS"
    kubectl rollout status deployment "$BACK_DEP" -n "$NS"

    echo "✅ Backend updated + restarted: $NS / $BACK_DEP"
  fi
done

echo
echo "🎉 Done."
echo "Frontend: hard refresh browser (Ctrl+Shift+R)."
echo "Backend: restarted where needed."
