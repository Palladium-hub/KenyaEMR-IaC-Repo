#!/usr/bin/env bash
set -euo pipefail

# Correct seed config location on PVC (must be different from runtime configuration)
SEED_MOUNT="/openmrs/distribution/openmrs_config"
RUNTIME_MOUNT="/openmrs/data/configuration"
SEED_SUBPATH_OK="distribution/openmrs_config"

KUBECTL="kubectl"

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }; }
need_cmd jq
need_cmd awk

discover_backends() {
  $KUBECTL get deploy -A --no-headers |
    awk '$1 ~ /^kenyaemr-tenant-/ && $2 ~ /-backend$/ {print $1"\t"$2}'
}

get_backend_volume_for_runtime_config() {
  local ns="$1" dep="$2"
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    .spec.template.spec.containers[]
    | select(.name=="backend")
    | (.volumeMounts // [])
    | map(select(.mountPath=="/openmrs/data/configuration"))
    | .[0].name // empty
  '
}

get_seed_mount_entry() {
  local ns="$1" dep="$2"
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    .spec.template.spec.containers[]
    | select(.name=="backend")
    | (.volumeMounts // [])
    | map(select(.mountPath=="/openmrs/distribution/openmrs_config"))[0] // empty
  '
}

get_seed_mount_index() {
  local ns="$1" dep="$2"
  $KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
    .spec.template.spec.containers[]
    | select(.name=="backend")
    | (.volumeMounts // [])
    | to_entries
    | map(select(.value.mountPath=="/openmrs/distribution/openmrs_config"))[0].key // empty
  '
}

restart_dep() {
  local ns="$1" dep="$2"
  $KUBECTL -n "$ns" rollout restart deploy/"$dep" >/dev/null
  $KUBECTL -n "$ns" rollout status deploy/"$dep" --timeout=300s >/dev/null
}

main() {
  mapfile -t rows < <(discover_backends)
  [ ${#rows[@]} -gt 0 ] || { echo "❌ No tenant backend deployments found."; exit 1; }

  echo "🔍 Scanning seed-config mounts across ${#rows[@]} backends..."
  echo ""

  fixed=0
  skipped=0
  for r in "${rows[@]}"; do
    ns="$(echo "$r" | awk '{print $1}')"
    dep="$(echo "$r" | awk '{print $2}')"

    echo "--------------------------------------------"
    echo "Target: $ns / $dep"

    # Runtime config PVC mount name (we reuse same volume)
    vol="$(get_backend_volume_for_runtime_config "$ns" "$dep")"
    if [ -z "$vol" ]; then
      echo "   ⚠️  Skipping: cannot detect volumeMount for $RUNTIME_MOUNT (likely not persisted / different chart)."
      skipped=$((skipped+1))
      continue
    fi
    echo "   📦 Runtime volume: $vol"

    seed_entry="$(get_seed_mount_entry "$ns" "$dep")"
    if [ -z "$seed_entry" ]; then
      echo "   ➖ No seed mount present at $SEED_MOUNT (nothing to fix here)."
      skipped=$((skipped+1))
      continue
    fi

    seed_subpath="$(echo "$seed_entry" | jq -r '.subPath // ""')"
    echo "   🔎 Current seed subPath: ${seed_subpath:-<none>}"

    # Wrong if it points to runtime configuration (or exactly equals configuration)
    if [ "$seed_subpath" = "configuration" ] || [ "$seed_subpath" = "configuration/" ] || [ "$seed_subpath" = "$(echo "$seed_subpath" | sed 's#/*$##')" ] && [ "$seed_subpath" = "configuration" ]; then
      : # handled above
    fi

    if [ "$seed_subpath" = "configuration" ]; then
      echo "   ❌ WRONG: seed mount points to runtime configuration -> causes 'cp: same file'"
    elif [ "$seed_subpath" = "$SEED_SUBPATH_OK" ]; then
      echo "   ✅ OK already ($SEED_SUBPATH_OK)"
      skipped=$((skipped+1))
      continue
    else
      # If seed_subpath equals runtime config subpath in general, also wrong
      runtime_subpath="$($KUBECTL -n "$ns" get deploy "$dep" -o json | jq -r '
        .spec.template.spec.containers[]
        | select(.name=="backend")
        | (.volumeMounts // [])
        | map(select(.mountPath=="/openmrs/data/configuration"))
        | .[0].subPath // ""
      ')"
      if [ -n "$runtime_subpath" ] && [ "$seed_subpath" = "$runtime_subpath" ]; then
        echo "   ❌ WRONG: seed subPath == runtime subPath ($runtime_subpath) -> causes 'cp: same file'"
      else
        echo "   ➖ Seed mount exists but not the known-wrong case. Leaving it."
        skipped=$((skipped+1))
        continue
      fi
    fi

    idx="$(get_seed_mount_index "$ns" "$dep")"
    if [ -z "$idx" ]; then
      echo "   ❌ Could not locate seed mount index to remove. Skipping."
      skipped=$((skipped+1))
      continue
    fi

    echo "   🧨 Removing wrong seed mount (index=$idx)..."
    $KUBECTL -n "$ns" patch deploy "$dep" --type='json' -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/$idx\"}]" >/dev/null

    echo "   🧩 Adding correct seed mount -> subPath=$SEED_SUBPATH_OK"
    $KUBECTL -n "$ns" patch deploy "$dep" --type='json' -p "[
      {
        \"op\":\"add\",
        \"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",
        \"value\":{
          \"name\":\"$vol\",
          \"mountPath\":\"$SEED_MOUNT\",
          \"subPath\":\"$SEED_SUBPATH_OK\"
        }
      }
    ]" >/dev/null

    echo "   🔄 Restarting..."
    restart_dep "$ns" "$dep"
    echo "   ✅ Fixed"
    fixed=$((fixed+1))
  done

  echo ""
  echo "✅ Done."
  echo "Fixed:   $fixed"
  echo "Skipped: $skipped"
  echo ""
  echo "Next: re-run your deploy_config_multi.sh safely after this."
}

main
