# KenyaEMR Deployment Scripts Training Guide

This guide is presentation-ready and path-neutral. Use
`<deployment-scripts-dir>` as the folder containing the scripts.

## 0. Terminology Quick Reference

`Namespace`
- A logical boundary in Kubernetes used to isolate tenant resources.

`Pod`
- The smallest runnable unit in Kubernetes (one or more containers).

`Deployment`
- Kubernetes object that manages pods and rolling updates/restarts.

`PVC` (PersistentVolumeClaim)
- A request for persistent storage by a pod/workload.

`PV` (PersistentVolume)
- The actual storage volume provisioned in the cluster.

`StorageClass`
- Defines how storage is provisioned (for example `microk8s-hostpath`).

`Volume`
- Storage definition attached to a pod spec.

`VolumeMount`
- Where a volume appears inside a container filesystem.

`subPath`
- Mounts only a subdirectory of a volume to a specific container path.

`InitContainer`
- A container that runs before app containers start; often used for
  cleanup, preparation, and bootstrap tasks.

`Ingress`
- Kubernetes resource that routes external HTTP/HTTPS traffic to
  services.

`IngressClass`
- Specifies which ingress controller handles an Ingress (for example
  `nginx`).

`Rollout restart`
- Controlled restart of deployment pods:
  `kubectl rollout restart deploy/<name>`.

`Runtime directory`
- Live data used by the running app (for example `/openmrs/data/...`).

`Seed directory`
- Baseline/source content used to repopulate runtime content on startup
  (for example `/openmrs/distribution/...`).

`OMOD`
- OpenMRS module package file (`.omod`) deployed to modules directories.

`configuration_checksums`
- OpenMRS checksum cache folder; deleting it forces re-evaluation of
  config changes.

`Preflight`
- Validation-only mode to check what will happen before changes.

`Dry-run` / `Audit`
- Simulated run that prints intended actions without applying them.

`kubectl context`
- The active cluster/user target used by `kubectl`.

## 1. Training Setup (Path-Neutral)

1. Export a neutral scripts location variable:
   `export DEPLOY_SCRIPTS_DIR="<deployment-scripts-dir>"`
2. Move into scripts directory:
   `cd "$DEPLOY_SCRIPTS_DIR"`
3. Confirm tooling:
   `kubectl version --client`, `jq --version`, `tar --version`
4. Confirm tenant deployments exist:
   `kubectl get deploy -A | rg 'kenyaemr-tenant-.*-(backend|frontend)'`
5. Confirm required archives exist in `/tmp` before deployment scripts:
   `spa.tgz`, `config.tgz`, `modules.tgz` (as needed).

## 2. First Deployment Prerequisite (Terraform Before Scripts)

Run this once for a new environment before any deployment scripts:

1. Export IaC repo path:
   `export IAC_REPO_DIR="<iac-repo-dir>"`
2. Move to IaC repo:
   `cd "$IAC_REPO_DIR"`
3. Run Terraform initialization and validation:
   `terraform fmt`
   `terraform init`
   `terraform validate`
4. For first environment deployment (recommended full apply):
   `terraform plan`
   `terraform apply`
5. Confirm core workloads are up (hub, keycloak, mysql, and at least
   one tenant workload as applicable).
6. Return to scripts directory and continue:
   `cd "$DEPLOY_SCRIPTS_DIR"`

Note:
- For later incremental tenant additions, targeted apply may be used:
  `terraform plan -target=module.<tenant>`
  `terraform apply -target=module.<tenant>`

## 3. Script Value Matrix

| Script | Primary Value | Best Use Case | Reliability |
|---|---|---|---|
| `fix_backends_multi.sh` | Standardizes backend runtime model | First-time hardening across all tenants | High |
| `fix_seed_config_mounts_multi.sh` | Removes seed/runtime config collision | `cp: same file` or bad seed subPath | High |
| `enable_persist_multi.sh` | Makes SPA updates durable | Before SPA deployment | High |
| `enable_backend_persist_multi.sh` | Makes backend config/modules durable | Before backend asset deployment | High |
| `deploy_modules_multi.sh` | Safest modules rollout | Routine module upgrades | High |
| `deploy_config_multi.sh` | Safe config rollout with preflight/dry-run | Routine config changes | High |
| `deploy_spa_multi.sh` | Single flow for SPA + optional backend | Guided multi-asset push per tenant | Medium |
| `deploy_backend_assets.sh` | Upload from local folders (not tgz) | Dev/ops workflow from unpacked assets | Medium |
| `deploy_assets_multi.sh` | Combined deploy (legacy style) | SPA-only use or after script fix | Low-Medium |
| `disable_spa_persistence.sh` | Revert SPA persistence | Controlled rollback | Low (needs care) |

## 4. Recommended Training Sequence (and Why)

1. `fix_backends_multi.sh`
2. `fix_seed_config_mounts_multi.sh`
3. `enable_persist_multi.sh`
4. `deploy_modules_multi.sh`
5. `deploy_config_multi.sh`
6. `deploy_spa_multi.sh`

Why this order:
- You first normalize storage and mounts.
- You then remove known config mount conflicts.
- You ensure persistence before any content push.
- You deploy backend modules/config first, then frontend SPA.

## 5. Deep Script Explanations

### 5.1 `fix_backends_multi.sh`

Purpose:
- Baseline hardening for all backend deployments.

Usefulness:
- Prevents drift across tenants.
- Ensures the backend can safely support repeat module/config rollouts.
- Reduces common startup failures caused by missing seed mount/init setup.

What it does internally:
- Discovers `kenyaemr-tenant-*/*-backend`.
- Checks if a PVC-backed volume exists.
- If missing, creates PVC (`<backend>-data-pvc`) and patches deployment
  with `data-pv` + subPath mounts for:
  `/openmrs/data/modules`,
  `/openmrs/data/configuration`,
  `/openmrs/data/configuration_checksums`.
- Ensures seed mount exists at
  `/openmrs/distribution/openmrs_modules`.
- Ensures `clean-openmrs-data` initContainer exists.
- Restarts only changed deployments.

How to run:
1. `cd "$DEPLOY_SCRIPTS_DIR"`
2. `./fix_backends_multi.sh`
3. Review final `Fixed/Skipped/Failed` counts.

Success indicators:
- Deployment has seed mount and cleaner initContainer.
- Rollouts complete without timeout.

### 5.2 `fix_seed_config_mounts_multi.sh`

Purpose:
- Corrects seed config mount mapping to avoid copy conflicts.

Usefulness:
- Fixes the `cp: same file` failure mode.
- Restores proper separation between seed and runtime config locations.

What it does internally:
- Scans all tenant backends.
- Reads runtime config mount volume (`/openmrs/data/configuration`).
- Reads seed config mount (`/openmrs/distribution/openmrs_config`).
- If seed subPath wrongly equals runtime config subPath, it removes the
  wrong mount and adds correct subPath:
  `distribution/openmrs_config`.
- Restarts affected deployments.

How to run:
1. `cd "$DEPLOY_SCRIPTS_DIR"`
2. `./fix_seed_config_mounts_multi.sh`
3. Re-run config deployment after fixes.

Success indicators:
- Wrong seed subPath no longer points to runtime config.
- Backend rollout succeeds and no copy-conflict errors in logs.

### 5.3 `enable_persist_multi.sh`

Purpose:
- Enables frontend SPA persistence tenant-by-tenant.

Usefulness:
- Prevents SPA updates from disappearing on pod restart.
- Supports safe preview via `PREFLIGHT` and `DRY_RUN`.

What it does internally:
- Discovers frontend deployments (`*-frontend`).
- Detects persistence by checking whether SPA mount path is backed by a
  PVC claim.
- Creates `<frontend>-spa-pvc` if missing.
- Patches deployment volume and mount at SPA path.
- Restarts deployment and verifies persistence was applied.

How to run:
1. `cd "$DEPLOY_SCRIPTS_DIR"`
2. Optional validation:
   `PREFLIGHT=1 ./enable_persist_multi.sh`
3. Optional dry-run:
   `DRY_RUN=1 ./enable_persist_multi.sh`
4. Actual:
   `./enable_persist_multi.sh`
5. Select `all` or chosen indexes.

Tunable variables:
- `DEST` (default `/usr/share/nginx/html/openmrs/spa`)
- `SC` (default `microk8s-hostpath`)
- `SIZE` (default `2Gi`)

### 5.4 `enable_backend_persist_multi.sh`

Purpose:
- Enables backend data persistence for modules/config/checksums.

Usefulness:
- Core prerequisite for durable backend assets.
- Supports interactive and one-tenant non-interactive mode.

What it does internally:
- Finds backend deployments.
- Creates `<backend>-data-pvc` if needed.
- Uses `jq` transformation + `kubectl apply` to enforce:
  `data-pv` volume and mounts for modules/config/checksums.
- Restarts rollout and waits for status.

How to run:
1. Interactive:
   `./enable_backend_persist_multi.sh`
2. One tenant:
   `./enable_backend_persist_multi.sh --ns <namespace> --dep <backend-deployment>`

Success indicators:
- Backend deployment shows expected three mounts.
- Pod restarts cleanly.

### 5.5 `deploy_modules_multi.sh`

Purpose:
- Safest module deployment path from `/tmp/modules.tgz`.

Usefulness:
- Handles seed-runtime lifecycle correctly.
- Includes built-in duplicate module detection after rollout.
- Includes debug collection for failed tenants.

What it does internally:
- Resolves usable `kubectl` command.
- Discovers backend deployments and target selection.
- Detects target container by mount discovery (not hard-coded by name).
- Detects PVC volume backing `/openmrs/data/modules`.
- Ensures seed mount + cleaner initContainer exist.
- Restarts once to apply patches/init logic.
- Uploads archive into pod and extracts to seed dir
  `/openmrs/distribution/openmrs_modules`.
- Restarts again so runtime modules are reseeded.
- Verifies duplicate OMOD groups in runtime dir.

How to run:
1. `ls -lh /tmp/modules.tgz`
2. `cd "$DEPLOY_SCRIPTS_DIR"`
3. `./deploy_modules_multi.sh`
4. Choose targets.

Success indicators:
- `Done: <ns> / <dep>` per tenant.
- Duplicate groups reported as `0`.

### 5.6 `deploy_config_multi.sh`

Purpose:
- Controlled configuration deployment from `/tmp/config.tgz`.

Usefulness:
- Includes `--preflight`, `--dry-run`, and `--audit`.
- Clears stale checksums and runtime config before extract.

What it does internally:
- Resolves `kubectl` binary/alias.
- Discovers backend deployments and prompts target selection.
- Finds pod by `app=<dep>` label, then fallback selector.
- Waits pod Ready.
- Uploads archive to `/tmp/config.tgz` in pod.
- Removes `/openmrs/data/configuration_checksums`.
- Wipes runtime config contents and extracts new config to
  `/openmrs/data/configuration`.
- Restarts deployment.

How to run:
1. `ls -lh /tmp/config.tgz`
2. `./deploy_config_multi.sh --preflight`
3. `./deploy_config_multi.sh --dry-run` (optional)
4. `./deploy_config_multi.sh` (actual)

Success indicators:
- No extraction errors.
- Backend rollout completes.
- Expected config appears in runtime path.

### 5.7 `deploy_spa_multi.sh`

Purpose:
- Combined tenant-wise deployment for SPA and optional backend assets.

Usefulness:
- Helpful for guided operator sessions with one interactive flow.
- Can deploy SPA-only or include backend config/modules.

What it does internally:
- Validates selected archives in `/tmp`.
- Extracts to local work dirs under `/tmp/deploy-work`.
- Discovers frontends and lets user pick tenants.
- For SPA:
  wipes SPA directory except `openmrs-spa.env.json`, then extracts.
- For backend:
  derives backend name from frontend name, optionally invokes
  persistence helpers, copies config/modules, restarts backend.

How to run:
1. Ensure selected archives exist in `/tmp`.
2. `cd "$DEPLOY_SCRIPTS_DIR"`
3. `./deploy_spa_multi.sh`
4. Choose assets (`1/2/3/4`) and target tenants.

Caution:
- Backend mount checks and destinations use relative `data/...` paths.
- Validate this matches your backend container filesystem.

### 5.8 `deploy_assets_multi.sh`

Purpose:
- Legacy combined deploy with separate frontend/backend selections.

Usefulness:
- Interactive and broad, but should be treated as secondary tooling.

What it does internally:
- Supports SPA, config, modules, or all.
- SPA path:
  extracts `spa.tgz`, wipes SPA (except env json), streams files to pod.
- Backend path:
  attempts stdin upload and Python extraction inside pod, then restarts.
- Offers to call persistence helpers when non-persisted deployments are
  detected.

How to run:
1. Ensure required archives exist in `/tmp`.
2. `cd "$DEPLOY_SCRIPTS_DIR"`
3. `./deploy_assets_multi.sh`
4. Choose asset modes and targets.

Known risk:
- Embedded Python block initializes `kind` and `appdata` as empty
  strings, which makes backend extraction logic unreliable.
- Recommendation:
  use `deploy_modules_multi.sh` and `deploy_config_multi.sh` for
  production training unless this script is fixed.

### 5.9 `deploy_backend_assets.sh`

Purpose:
- Upload backend assets directly from local folders.

Usefulness:
- Good when teams work from unpacked repo content, not tarballs.
- Useful for rapid updates during development workshops.

What it does internally:
- Discovers backend deployments and lets operator select tenants.
- Prompts for asset type:
  config, modules, or both.
- Prompts for local repo root and optional actions:
  delete checksums, enable persistence.
- Copies folder/file content with tar streams into pod.
- Sets ownership (`1001:0` when possible).
- Restarts backend and waits for rollout.

How to run:
1. Ensure local sources exist:
   `<repo>/configuration/` and/or `<repo>/modules/*.omod`
2. `cd "$DEPLOY_SCRIPTS_DIR"`
3. `./deploy_backend_assets.sh`
4. Follow prompts.

Caution:
- Persistence style here mounts `/openmrs/data` as a whole, which may
  differ from subPath strategy used in other scripts.

### 5.10 `disable_spa_persistence.sh`

Purpose:
- Rollback tool to remove SPA persistence.

Usefulness:
- Lets you revert to image-bundled SPA behavior.
- Useful for troubleshooting persistence-related issues.

What it does internally:
- Discovers frontend deployments and persistence state.
- Prompts target selection and confirmation.
- Patches deployment to remove `volumeMounts` and `volumes`.
- Restarts frontend deployment.
- Optionally deletes PVC `<frontend>-spa-pvc`.

How to run:
1. `cd "$DEPLOY_SCRIPTS_DIR"`
2. `./disable_spa_persistence.sh`
3. Select targets and confirm.

High-risk note:
- Script removes whole `volumeMounts` and `volumes` arrays.
- If deployment has other mounts/volumes, manual review is required
  before use.

## 6. Post-Deployment Validation (All Flows)

Run for each tenant:

```bash
kubectl get pods -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-backend -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant>
kubectl logs deploy/<tenant>-backend -n kenyaemr-tenant-<tenant> --tail=200
kubectl get ingress -n kenyaemr-tenant-<tenant>
```

Browser validation:
- Hard refresh SPA after deployment: `Ctrl+Shift+R`.

## 7. Cleanup and Governance Notes

- There is an extra malformed executable artifact in the scripts
  directory (`%sn % (tgz, dest))\nPY\n`) that should be reviewed and
  removed from managed training material.
- For classroom reliability, standardize on:
  `fix_backends_multi.sh`,
  `fix_seed_config_mounts_multi.sh`,
  `deploy_modules_multi.sh`,
  `deploy_config_multi.sh`,
  `deploy_spa_multi.sh`.
