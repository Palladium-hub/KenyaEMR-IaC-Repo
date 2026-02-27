#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="${TMP_DIR:-/tmp}"
MYSQL_NS="${MYSQL_NS:-mysql}"
MYSQL_POD="${MYSQL_POD:-mysql-0}"
MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-training}"

RUNTIME_PROPS_CANDIDATES=(
  "/openmrs/data/openmrs-runtime.properties"
  "/openmrs/openmrs-runtime.properties"
)

MODE="run"   # run | preflight | audit

usage() {
  cat <<USAGE
Usage:
  ./deploy_db_source_picker_multi.sh [--preflight|--dry-run|--audit]
Options:
  --preflight         Validate mappings and availability only (no changes)
  --dry-run|--audit   Print planned actions only (no changes)
Env overrides:
  TMP_DIR=/tmp
  MYSQL_NS=mysql
  MYSQL_POD=mysql-0
  MYSQL_ROOT_USER=root
  MYSQL_ROOT_PASS=training
USAGE
}

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
  echo "❌ kubectl not found. Run this on the node that has kubectl/microk8s."
  exit 1
fi
# --------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --preflight) MODE="preflight"; shift ;;
    --dry-run|--audit) MODE="audit"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1"; usage; exit 1 ;;
  esac
done

die() { echo "❌ $*"; exit 1; }

get_backend_pod() {
  local ns="$1" dep="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" get pod -l "app=$dep" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

wait_backend_ready() {
  local ns="$1" pod="$2"
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=240s >/dev/null
}

get_db_from_backend() {
  local ns="$1" pod="$2"

  local props_path=""
  for p in "${RUNTIME_PROPS_CANDIDATES[@]}"; do
    # shellcheck disable=SC2086
    if $KUBECTL -n "$ns" exec "$pod" -- sh -lc "test -f '$p'" >/dev/null 2>&1; then
      props_path="$p"
      break
    fi
  done
  [ -n "$props_path" ] || return 10

  # shellcheck disable=SC2086
  local url
  url="$($KUBECTL -n "$ns" exec "$pod" -- sh -lc "grep -E '^[[:space:]]*connection\\.url=' '$props_path' | head -n1" 2>/dev/null | tr -d '\r' || true)"
  [ -n "$url" ] || return 11

  url="${url#*=}"
  local db
  db="$(echo "$url" | awk -F/ '{print $NF}' | awk -F'?' '{print $1}')"
  [ -n "$db" ] || return 12
  echo "$db"
}

# IMPORTANT: this function must print ONLY the pod path to STDOUT (so the caller can capture it).
# Any logs MUST go to STDERR.
copy_sql_to_mysql_pod() {
  local file="$1"
  local base
  base="$(basename "$file")"
  local pod_path="/tmp/$base"

  [ -f "$file" ] || die "SQL file not found on this server: $file"

  if [ "$MODE" = "audit" ]; then
    echo "📤 [DRY-RUN] Would copy $file → $MYSQL_NS/$MYSQL_POD:$pod_path" >&2
    echo "$pod_path"
    return 0
  fi

  # If already present in mysql pod, skip copying
  # shellcheck disable=SC2086
  if $KUBECTL -n "$MYSQL_NS" exec "$MYSQL_POD" -- sh -lc "test -f '$pod_path'" >/dev/null 2>&1; then
    echo "ℹ️  Already in mysql pod: $MYSQL_NS/$MYSQL_POD:$pod_path (skip copy)" >&2
    echo "$pod_path"
    return 0
  fi

  echo "📤 Copying $file → $MYSQL_NS/$MYSQL_POD:$pod_path" >&2
  # shellcheck disable=SC2086
  $KUBECTL -n "$MYSQL_NS" cp "$file" "$MYSQL_POD:$pod_path" >/dev/null

  echo "$pod_path"
}

mysql_import_one() {
  local db="$1" pod_path="$2"

  local cmd=""
  if [[ "$pod_path" == *.sql.gz ]]; then
    cmd="gunzip -c '$pod_path' | mysql -u'$MYSQL_ROOT_USER' -p'$MYSQL_ROOT_PASS' '$db'"
  else
    cmd="mysql -u'$MYSQL_ROOT_USER' -p'$MYSQL_ROOT_PASS' '$db' < '$pod_path'"
  fi

  if [ "$MODE" = "audit" ]; then
    echo "   [DRY-RUN] $cmd"
    return 0
  fi

  echo "   ▶ Importing into DB: $db"
  # shellcheck disable=SC2086
  $KUBECTL -n "$MYSQL_NS" exec "$MYSQL_POD" -- sh -lc "$cmd"
  echo "   ✅ Done: $db"
}

# 1) Pick SQL scripts from /tmp
mapfile -t SQLS < <(ls -1 "$TMP_DIR"/*.sql "$TMP_DIR"/*.sql.gz 2>/dev/null || true)
[ ${#SQLS[@]} -gt 0 ] || die "No SQL scripts found in $TMP_DIR (expected *.sql or *.sql.gz)."

echo "🗂  SQL scripts found in $TMP_DIR:"
i=1
for f in "${SQLS[@]}"; do
  printf "  [%d] %s\n" "$i" "$(basename "$f")"
  i=$((i+1))
done
echo
echo "Select SQL script(s) to run:"
echo "  - all        -> run ALL listed"
echo "  - 1,3,5      -> run selected"
read -r -p "👉 SQL Selection: " SQL_SEL

SQL_TARGETS=()
SQL_SEL="$(echo "$SQL_SEL" | tr -d '[:space:]')"
if [[ "$SQL_SEL" =~ ^([Aa][Ll][Ll])$ ]]; then
  for n in $(seq 1 ${#SQLS[@]}); do SQL_TARGETS+=("$n"); done
else
  IFS=',' read -ra parts <<< "$SQL_SEL"
  for p in "${parts[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid SQL selection: $p"
    SQL_TARGETS+=("$p")
  done
fi

SEL_SQL_FILES=()
for idx in "${SQL_TARGETS[@]}"; do
  f="${SQLS[$((idx-1))]:-}"
  [ -n "$f" ] || die "SQL index out of range: $idx"
  SEL_SQL_FILES+=("$f")
done

echo
echo "✅ Selected SQL script(s):"
for f in "${SEL_SQL_FILES[@]}"; do echo "  - $f"; done
echo

# 2) Discover and pick backend deployments
echo "🔍 Discovering KenyaEMR tenant backend deployments..."
mapfile -t DEPS < <(
  # shellcheck disable=SC2086
  $KUBECTL get deploy -A --no-headers |
  awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-backend$/ {print $1"\t"$2}'
)

[ ${#DEPS[@]} -gt 0 ] || die "No backend deployments found (expected kenyaemr-tenant-* / *-backend)."

echo
i=1
for d in "${DEPS[@]}"; do
  ns="$(echo "$d" | awk '{print $1}')"
  dep="$(echo "$d" | awk '{print $2}')"
  printf "  [%d] %s / %s\n" "$i" "$ns" "$dep"
  i=$((i+1))
done

echo
echo "Select backend(s) to apply the SQL against:"
echo "  - all        -> ALL backends"
echo "  - 1,4        -> selected"
read -r -p "👉 Backend Selection: " DEP_SEL

DEP_TARGETS=()
DEP_SEL="$(echo "$DEP_SEL" | tr -d '[:space:]')"
if [[ "$DEP_SEL" =~ ^([Aa][Ll][Ll])$ ]]; then
  for n in $(seq 1 ${#DEPS[@]}); do DEP_TARGETS+=("$n"); done
else
  IFS=',' read -ra parts <<< "$DEP_SEL"
  for p in "${parts[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid backend selection: $p"
    DEP_TARGETS+=("$p")
  done
fi

SEL_DEPS=()
for idx in "${DEP_TARGETS[@]}"; do
  d="${DEPS[$((idx-1))]:-}"
  [ -n "$d" ] || die "Backend index out of range: $idx"
  SEL_DEPS+=("$d")
done

echo
echo "✅ Selected backend(s):"
for d in "${SEL_DEPS[@]}"; do
  echo "  - $(echo "$d" | awk '{print $1 " / " $2}')"
done
echo

# 3) Preflight: verify mysql pod and resolve DBs
echo "🧪 Preflight checks..."
# shellcheck disable=SC2086
$KUBECTL -n "$MYSQL_NS" get pod "$MYSQL_POD" >/dev/null 2>&1 || die "MySQL pod not found: $MYSQL_NS/$MYSQL_POD"

RESOLVED=()
FAILS=0

for d in "${SEL_DEPS[@]}"; do
  ns="$(echo "$d" | awk '{print $1}')"
  dep="$(echo "$d" | awk '{print $2}')"

  pod="$(get_backend_pod "$ns" "$dep")"
  if [ -z "$pod" ]; then
    echo "   ❌ $ns/$dep: could not find pod (label app=$dep)."
    FAILS=$((FAILS+1))
    continue
  fi

  if ! wait_backend_ready "$ns" "$pod" >/dev/null 2>&1; then
    echo "   ❌ $ns/$dep: pod not Ready ($pod)."
    FAILS=$((FAILS+1))
    continue
  fi

  db=""
  if db="$(get_db_from_backend "$ns" "$pod" 2>/dev/null)"; then
    echo "   ✅ $ns/$dep → DB=$db (pod=$pod)"
    RESOLVED+=("$ns|$dep|$pod|$db")
  else
    echo "   ❌ $ns/$dep: could not derive DB from runtime properties (pod=$pod)."
    FAILS=$((FAILS+1))
  fi
done

[ $FAILS -eq 0 ] || die "Preflight failed for $FAILS backend(s). Fix those first."

echo
echo "📌 Plan summary:"
echo "  SQL scripts:"
for f in "${SEL_SQL_FILES[@]}"; do echo "   - $(basename "$f")"; done
echo "  Targets:"
for r in "${RESOLVED[@]}"; do
  ns="$(echo "$r" | cut -d'|' -f1)"
  dep="$(echo "$r" | cut -d'|' -f2)"
  db="$(echo "$r" | cut -d'|' -f4)"
  echo "   - $ns/$dep -> $db"
done
echo

if [ "$MODE" = "preflight" ]; then
  echo "✅ Preflight mode complete (no changes made)."
  exit 0
fi

# 4) Copy SQLs into mysql pod then import to each DB
echo "🚀 Executing imports (mode=$MODE)..."
echo

MYSQL_POD_PATHS=()
for f in "${SEL_SQL_FILES[@]}"; do
  MYSQL_POD_PATHS+=("$(copy_sql_to_mysql_pod "$f")")
done

echo
for r in "${RESOLVED[@]}"; do
  ns="$(echo "$r" | cut -d'|' -f1)"
  dep="$(echo "$r" | cut -d'|' -f2)"
  db="$(echo "$r" | cut -d'|' -f4)"

  echo "--------------------------------------------"
  echo "🎯 Target: $ns/$dep  (DB: $db)"

  for p in "${MYSQL_POD_PATHS[@]}"; do
    echo " 🧾 Script: $(basename "$p")"
    mysql_import_one "$db" "$p"
  done

  echo "✅ Completed: $db"
done

echo
echo "🎉 All imports completed."
echo "Tip: If OpenMRS caches concepts/metadata, restart the selected backend deployments afterwards."
