# KenyaEMR Multi-Tenancy Deployment SOP

## Assets Upload, Backend Standardization, and Database Deployment Guide

------------------------------------------------------------------------

## 0. Add New Tenant and Deploy (Detailed Local IaC Flow)

Run all commands from: cloned 

KenyaEMR-IaC-Repo

### 0.1 Preflight Checks

``` bash
pwd
kubectl config current-context
kubectl get ns
terraform version
helm version
```

### 0.2 Files You Must Edit for a New Tenant

-   main Terraform tenant definition: main.tf
-   MySQL bootstrap SQL source of truth: modules/mysql-shared/init/tenants.sql
-   Tenant module variable defaults (only if changing global defaults):
    modules/kenyaemr-tenant/variables.tf
-   Helm tenant template behavior (only if changing platform behavior):
    charts/kenyaemr-tenant/templates/*.yaml

### 0.3 Define Tenant Inputs Before Editing

Use one consistent naming convention:

-   tenant_name: north
-   namespace: kenyaemr-tenant-north
-   db_schema: openmrs_north
-   db_user: north_user
-   db_password: north_pass
-   ingress host (from chart): north.hmislocal.org
-   backend deployment: north-backend
-   frontend deployment: north-frontend
-   OIDC realm/client: north / north-spa

### 0.4 Add MySQL Schema/User in Source-Control

Edit:

modules/mysql-shared/init/tenants.sql

Add a block like this:

``` sql
-- north Tenant
CREATE DATABASE IF NOT EXISTS openmrs_north CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'north_user'@'%' IDENTIFIED BY 'north_pass';
GRANT ALL PRIVILEGES ON openmrs_north.* TO 'north_user'@'%';
```

Important: this file is mounted into `/docker-entrypoint-initdb.d` and
is applied only when MySQL initializes a fresh data directory.

### 0.5 Create DB/User on Existing Running MySQL

If MySQL PVC already exists, run SQL manually on the live pod:

``` bash
TENANT="north"
DB_SCHEMA="openmrs_north"
DB_USER="north_user"
DB_PASS="north_pass"
MYSQL_POD=$(kubectl get pod -n mysql -l app=mysql -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n mysql "$MYSQL_POD" -- mysql -uroot -ptraining -e "
CREATE DATABASE IF NOT EXISTS ${DB_SCHEMA} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_SCHEMA}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;"
```

Verify:

``` bash
kubectl exec -n mysql "$MYSQL_POD" -- mysql -uroot -ptraining -e "SHOW DATABASES LIKE 'openmrs_north';"
kubectl exec -n mysql "$MYSQL_POD" -- mysql -uroot -ptraining -e "SHOW GRANTS FOR 'north_user'@'%';"
```

### 0.6 Add Tenant Module in Terraform

Edit:

main.tf

Add a new module block:

``` hcl
module "north" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "north"
  db_schema      = "openmrs_north"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "north_user"
  db_password    = "north_pass"
  backend_image  = "hakeemraj/kenyaemr-backend:latest"
  frontend_image = "hakeemraj/kenyaemr-frontend-ksm:latest"
  oidc_realm     = "north"
  oidc_client_id = "north-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/north"
}
```

### 0.7 Configure Backend/Frontend Images Correctly

Where images are defined for each tenant:

-   main.tf in each tenant module block:
    `backend_image`, `frontend_image`

How images are consumed:

-   charts/kenyaemr-tenant/templates/backend-deployment.yaml
-   charts/kenyaemr-tenant/templates/frontend-deployment.yaml
-   Current behavior: `imagePullPolicy: Always`

Good practice:

-   Use immutable tags or digests for production (for example,
    `repo/image@sha256:...`).
-   Keep backend/frontend image combinations compatible for the same
    release.

### 0.8 Configure Private Registry Pull (If Needed)

If images are private, create pull secret in tenant namespace:

``` bash
kubectl create secret docker-registry regcred \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<password> \
  --docker-email=<email> \
  -n kenyaemr-tenant-<tenant>
```

Attach secret to default service account:

``` bash
kubectl patch serviceaccount default \
  -n kenyaemr-tenant-<tenant> \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

If you want this managed by Helm/Terraform instead of manual patching,
add `imagePullSecrets` support into backend/frontend templates and pass
it via module `set` values.

### 0.9 OIDC, Ingress, and Runtime Config Checkpoints

Files to validate:

-   charts/kenyaemr-tenant/templates/runtimes-configmap.yaml
-   charts/kenyaemr-tenant/templates/oauth2-configmap.yaml
-   charts/kenyaemr-tenant/templates/spa-env-configmap.yaml
-   charts/kenyaemr-tenant/templates/ingress.yaml

Confirm these align before deploy:

-   realm/client values match Keycloak setup
-   redirect URLs use tenant host
-   ingress host resolves for `<tenant>.hmislocal.org`
-   wildcard TLS secret `hmislocal-wildcard-tls` is available in tenant
    namespace

### 0.10 Update Hub Landing Page Tenant Source (Required)

Landing page tenant options are pulled from:

-   charts/kenyaemr-hub/values.yaml -> `hub.knownTenants`

Terraform currently deploys hub with this exact file:

-   modules/kenyaemr-hub/main.tf -> `file("${path.module}/../../charts/kenyaemr-hub/values.yaml")`

Add the new tenant there:

``` yaml
hub:
  knownTenants:
    - name: north
      branding: North Region
```

Rules:

-   `knownTenants[].name` must exactly match `tenant_name` in main.tf
-   `branding` is display text only (can differ)
-   landing template source is
    charts/kenyaemr-hub/templates/hub-landing-configmap.yaml

Current redirect template line:

``` html
<option value="https://{{ .name }}.hmislocal.org/openmrs">{{ .branding }}</option>
```

If you use `charts/kenyaemr-hub/files/hub-values.yaml` in manual Helm
flows, keep it synchronized with `charts/kenyaemr-hub/values.yaml`.

Deploy hub after updating knownTenants:

``` bash
terraform plan -target=module.hub
terraform apply -target=module.hub
```

Validate rendered options:

``` bash
kubectl get cm hub-kenyaemr-hub-landing -n hub -o yaml | rg -n "<option|north"
```

### 0.11 Conformity Matrix (Must Match Across Files)

Use the same tenant identity across all layers:

-   Tenant key (`north`):
    main.tf (`module "north"`, `tenant_name = "north"`) and
    charts/kenyaemr-hub/values.yaml (`knownTenants[].name`)
-   DB schema (`openmrs_north`):
    modules/mysql-shared/init/tenants.sql and main.tf (`db_schema`)
-   DB user/password:
    modules/mysql-shared/init/tenants.sql and main.tf (`db_user`,
    `db_password`)
-   OIDC:
    main.tf (`oidc_realm`, `oidc_client_id`, `oidc_issuer`) and tenant
    templates under charts/kenyaemr-tenant/templates
-   Backend/frontend images:
    main.tf (`backend_image`, `frontend_image`) and deployment templates
    in charts/kenyaemr-tenant/templates
-   Landing label:
    charts/kenyaemr-hub/values.yaml (`knownTenants[].branding`)

Domain/host consistency notes:

-   Hub ingress host comes from
    charts/kenyaemr-hub/values.yaml (`ingress.host`)
-   Hub landing tenant redirect host is currently hardcoded in
    charts/kenyaemr-hub/templates/hub-landing-configmap.yaml
-   Tenant ingress and OIDC URLs are currently hardcoded to `hmislocal.org`
    in:
    charts/kenyaemr-tenant/templates/ingress.yaml,
    runtimes-configmap.yaml, oauth2-configmap.yaml, spa-env-configmap.yaml
-   `hub.domain` in charts/kenyaemr-hub/values.yaml is currently
    informational and not directly consumed by templates

### 0.12 Terraform Deploy Sequence

``` bash
terraform fmt
terraform init
terraform validate
terraform plan -target=module.<tenant>
terraform apply -target=module.<tenant>
```

Optional full environment deploy:

``` bash
terraform plan
terraform apply
```

### 0.13 Post-Deploy Validation

``` bash
kubectl get ns kenyaemr-tenant-<tenant>
kubectl get deploy -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-backend -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant>
kubectl get pods -n kenyaemr-tenant-<tenant>
kubectl get ingress -n kenyaemr-tenant-<tenant>
kubectl get cm <tenant>-runtime-config -n kenyaemr-tenant-<tenant> -o yaml
```

If pods fail to start:

-   `kubectl describe pod <pod-name> -n kenyaemr-tenant-<tenant>` for
    ImagePullBackOff or config errors
-   `kubectl logs deploy/<tenant>-backend -n kenyaemr-tenant-<tenant>`
    for DB/auth startup issues

### 0.14 Continue Asset and DB Deployment

After tenant is created and healthy, continue from Section 5 onward in
this SOP:

-   backend standardization
-   modules deployment
-   configuration deployment
-   SPA deployment
-   DB script deployment

------------------------------------------------------------------------

## 1. Purpose

This document provides a complete Standard Operating Procedure (SOP)
for:

-   Setting up KenyaEMR multi-tenant pods
-   Standardizing backend and frontend persistence
-   Deploying latest modules, configuration, and SPA assets
-   Running database scripts safely across selected tenants
-   Using asset upload automation scripts correctly

This SOP is designed for DevOps engineers and system administrators
managing multiple KenyaEMR tenant environments.

------------------------------------------------------------------------

# 2. Architecture Overview

Each tenant follows this structure:

Namespace: kenyaemr-tenant-`<tenant>`{=html}

Deployments: - `<tenant>`{=html}-backend - `<tenant>`{=html}-frontend

Database: - One MySQL database per tenant (e.g. openmrs_nairobi,
openmrs_coast)

Core directories inside backend:

Runtime (PVC): - /openmrs/data/modules - /openmrs/data/configuration -
/openmrs/data/configuration_checksums

Seed (Distribution): - /openmrs/distribution/openmrs_modules -
/openmrs/distribution/openmrs_config

IMPORTANT: Seed and Runtime directories must NEVER resolve to the same
physical path.

------------------------------------------------------------------------

# 3. Golden Deployment Order

When deploying latest assets:

1.  Fix backend mounts (one-time standardization)
2.  Enable persistence
3.  Deploy modules
4.  Deploy configuration
5.  Deploy SPA
6.  Deploy DB scripts (if needed)
7.  Restart backends if metadata changed

------------------------------------------------------------------------

# 4. Asset Upload Script (Local → Remote)

Script: deploy_assets_upload_traininghub.sh
deploy_assets_upload_frenchhub.sh

Purpose: - Compress frontend, configuration, and modules - Upload to
remote server /tmp

Default output on remote server: - /tmp/spa.tgz - /tmp/config.tgz -
/tmp/modules.tgz

Preflight checks: - Verifies SSH key exists - Validates SSH connection -
Confirms folder structure

Usage:

./deploy_assets_upload_traininghub.sh Select: 1 = SPA 2 = Configuration
3 = Modules 4 = All

Override target without editing script:

REMOTE_HOST=13.247.118.240 ./deploy_assets_upload_traininghub.sh

------------------------------------------------------------------------

# 5. Backend Standardization (One-Time)

Run:

./fix_backends_multi.sh

Ensures: - Seed modules mount exists - Cleaner initContainer exists -
Runtime modules are wiped on restart

Fix seed config mount mismatch:

./fix_seed_config_mounts_multi.sh

Prevents crash: cp: seed and runtime are the same file

------------------------------------------------------------------------

# 6. Deploying Modules

1.  Upload modules.tgz to /tmp on remote
2.  Run:

./deploy_modules_multi.sh

Expected behavior: - Extracts modules to seed directory - Restarts
backend - Verifies no duplicate OMOD files

If duplicates appear: Re-run fix_backends_multi.sh

------------------------------------------------------------------------

# 7. Deploying Configuration

1.  Upload config.tgz
2.  Run:

./deploy_config_multi.sh

This: - Cleans runtime configuration - Removes configuration_checksums -
Restarts backend

If you see error: cp: same file

Run: ./fix_seed_config_mounts_multi.sh

------------------------------------------------------------------------

# 8. Deploying SPA

1.  Upload spa.tgz
2.  Run:

./deploy_spa_multi.sh

Ensure persistence enabled first:

./enable_persist_multi.sh

------------------------------------------------------------------------

# 9. Database Script Deployment

Use interactive picker:

./deploy_db_source_picker_multi.sh

Features: - Lists SQL scripts in /tmp - Lists backend deployments - Maps
backend → correct DB via runtime properties - Supports --preflight and
--audit modes

Recommended flow:

./deploy_db_source_picker_multi.sh --preflight
./deploy_db_source_picker_multi.sh --audit
./deploy_db_source_picker_multi.sh

If deploying concept dictionary or metadata: Restart backend after
import.

------------------------------------------------------------------------

# 10. Restarting Backends

If modules, config, or metadata changed:

kubectl rollout restart deploy/`<backend>`{=html} -n
`<namespace>`{=html}

Wait for rollout:

kubectl rollout status deploy/`<backend>`{=html} -n `<namespace>`{=html}

------------------------------------------------------------------------

# 11. Troubleshooting

Duplicate modules: Ensure cleaner initContainer exists.

Seed/runtime conflict: Fix mount mismatch.

Trigger permission denied: Grant TRIGGER privilege to DB user.

jq not found: Install via: sudo apt install jq

------------------------------------------------------------------------

# 12. First-Time Setup Checklist

1.  Verify kubectl access
2.  Verify MySQL pod running
3.  Standardize backends
4.  Fix seed config mounts
5.  Enable SPA persistence
6.  Deploy modules
7.  Deploy config
8.  Deploy SPA
9.  Deploy DB scripts if required
10. Restart backends

------------------------------------------------------------------------

# 13. Operational Best Practices

-   Always run preflight before production changes
-   Never deploy directly into runtime without seed consistency
-   Maintain consistent archive naming
-   Avoid manual pod patching for large tenant sets
-   Log all deployment operations

------------------------------------------------------------------------

END OF DOCUMENT
