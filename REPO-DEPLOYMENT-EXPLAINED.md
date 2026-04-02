# KenyaEMR-IaC-Repo: Active Architecture and Multitenant Deployment

This document explains the active deployment model for this repository.

It intentionally describes only the current image-based workflow. Legacy runtime deployment helpers are not part of the active operating model and are intentionally omitted from the documented repo tree below.

## 1. What this repository does

This repository provisions a multi-tenant KenyaEMR deployment on Kubernetes using:

- Terraform for orchestration
- Helm for tenant application manifests
- Prebuilt backend and frontend container images for application delivery

The active model is immutable-image deployment:

- backend application behavior is delivered in the backend image
- frontend SPA behavior is delivered in the frontend image
- tenant-specific infrastructure is created by Terraform + Helm
- runtime file-copy deployment is not part of the intended flow

## 2. Active repository tree

```text
KenyaEMR-IaC-Repo/
├── README.md
├── main.tf
├── REPO-DEPLOYMENT-EXPLAINED.md
├── SOP-Multitenancy-Setup-and-Assets-Deployment.md
├── charts/
│   └── kenyaemr-tenant/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── backend-deployment.yaml
│           ├── backend-service.yaml
│           ├── configMap.yaml
│           ├── frontend-deployment.yaml
│           ├── frontend-service.yaml
│           ├── ingress.yaml
│           ├── init-db-job.yaml
│           └── runtime-configmap.yaml
└── modules/
    ├── kenyaemr-tenant/
    │   ├── main.tf
    │   └── variables.tf
    └── mysql-shared/
        ├── main.tf
        └── init/
            └── tenants.sql
```

## 3. What each active path is for

### Root files

- `README.md`: minimal quick-start for Terraform usage.
- `main.tf`: root Terraform entrypoint. Defines providers, the shared MySQL module, and each tenant module.
- `REPO-DEPLOYMENT-EXPLAINED.md`: this repository walkthrough.
- `SOP-Multitenancy-Setup-and-Assets-Deployment.md`: operational SOP for environment setup and image-based multitenant deployment.

### `modules/mysql-shared`

This module deploys the shared MySQL service used by all tenants.

- `modules/mysql-shared/main.tf` creates:
  - a MySQL deployment named `mysql`
  - a Kubernetes service named `mysql`
  - a configmap containing bootstrap SQL
- `modules/mysql-shared/init/tenants.sql` contains the schema and user creation SQL for tenant databases.

How it fits the multitenant model:

- there is one shared MySQL server
- each tenant gets a separate schema
- each tenant gets a separate DB user/password
- tenant backend pods connect only to their own schema

### `modules/kenyaemr-tenant`

This module deploys one KenyaEMR tenant.

- `modules/kenyaemr-tenant/variables.tf` defines per-tenant inputs.
- `modules/kenyaemr-tenant/main.tf` creates:
  - one namespace: `kenyaemr-tenant-<tenant_name>`
  - one Helm release for that tenant

Inputs passed per tenant include:

- `tenant_name`
- `db_schema`
- `db_host`
- `db_user`
- `db_password`
- `backend_image`
- `frontend_image`
- `chart_path`

### `charts/kenyaemr-tenant`

This Helm chart renders the Kubernetes resources for one tenant.

- `Chart.yaml`: chart metadata.
- `values.yaml`: default values and placeholders.
- `templates/backend-deployment.yaml`: backend pod definition.
- `templates/backend-service.yaml`: backend service on port `8080`.
- `templates/frontend-deployment.yaml`: frontend pod definition.
- `templates/frontend-service.yaml`: frontend service on port `80`.
- `templates/runtime-configmap.yaml`: tenant runtime properties with DB connection settings.
- `templates/ingress.yaml`: external routing for frontend and backend paths.
- `templates/init-db-job.yaml`: optional pre-install/pre-upgrade restore hook logic.
- `templates/configMap.yaml`: currently empty and not active.

## 4. Multitenant environment model

Each tenant is isolated at the Kubernetes layer but shares the same MySQL server.

Per tenant, the repo creates:

- one namespace: `kenyaemr-tenant-<tenant>`
- one backend deployment: `<tenant>-backend`
- one backend service: `<tenant>-backend`
- one frontend deployment: `<tenant>-frontend`
- one frontend service: `<tenant>-frontend`
- one runtime configmap: `<tenant>-runtime-config`
- one ingress resource for tenant routing

Database isolation:

- shared MySQL host: `mysql.default.svc.cluster.local`
- tenant schema example: `openmrs_kayolesch`
- tenant user example: `kayole_user`

Request flow:

1. User browses to `http://<tenant>.local/openmrs/spa`
2. Ingress routes `/openmrs/spa...` to the tenant frontend service
3. Ingress routes `/openmrs...` to the tenant backend service
4. Backend reads tenant-specific DB settings from the runtime configmap
5. Backend connects to the shared MySQL server using that tenant's schema and credentials

## 5. Active deployment flow

### 5.1 First environment deployment

Run from the repository root:

```bash
terraform init
terraform plan
terraform apply
```

What happens:

1. Terraform connects to the Kubernetes cluster using local kubeconfig.
2. Terraform deploys the shared MySQL module.
3. Terraform deploys each tenant module.
4. Each tenant module installs the Helm chart into its own namespace.
5. Kubernetes schedules the backend and frontend pods.

### 5.2 Releasing changes the image-only way

The current intended release model is to ship changes in container images, not by copying files into running pods.

For an existing tenant release:

1. Build and publish the new backend and/or frontend image outside this repo.
2. Update the tenant image tags in `main.tf`.
3. Run:

```bash
terraform plan
terraform apply
```

What changes:

- Helm receives the new `backend_image` and/or `frontend_image` values.
- The tenant deployment is updated.
- Kubernetes rolls out new pods using the new image.

Important detail:

- `modules/kenyaemr-tenant/main.tf` sets `deployment.forceRedeployTimestamp = timestamp()`.
- That means each Terraform apply pushes a fresh timestamp into Helm values, which forces the Helm release to reconcile and helps trigger a rollout when needed.

### 5.3 Adding a new tenant

To add a new tenant:

1. Add the tenant schema/user block to `modules/mysql-shared/init/tenants.sql`.
2. Add a new tenant module block in `main.tf`.
3. Set the tenant's:
   - `tenant_name`
   - `db_schema`
   - `db_user`
   - `db_password`
   - `backend_image`
   - `frontend_image`
4. Run:

```bash
terraform plan
terraform apply
```

Result:

- the namespace is created
- the tenant Helm release is installed
- the new tenant backend/frontend become reachable through ingress

## 6. Environment settings required for multitenancy

These are the core environment assumptions for this repo.

### Kubernetes and tooling

Required on the operator machine:

- `terraform`
- `kubectl`
- `helm`
- access to a working kubeconfig at `~/.kube/config`

Required in the cluster:

- a working Kubernetes cluster
- an ingress controller that supports `ingressClassName: nginx`
- DNS or local host mapping for tenant hostnames

### Host resolution

The current ingress template uses tenant hosts in this form:

- `<tenant>.local`

That means local DNS or `/etc/hosts` entries must resolve those tenant names to the cluster ingress endpoint.

If you are testing locally, lock the tenant host mappings to localhost so network IP changes do not break browser access.

Add the tenant hosts to `/etc/hosts` on your workstation.

```bash
sudo nano /etc/hosts
```

Example:

```text
127.0.0.1 north.local
127.0.0.1 kayolesch.local
127.0.0.1 mbagathicrh.local
```

### Image packaging requirement

Because the active model is image-based:

- the backend image should already include the application state and content you expect at runtime
- the frontend image should already include the SPA assets you want to serve
- operational updates should happen by publishing a new image tag and applying Terraform again

## 7. Current repo behavior that matters operationally

### Shared MySQL is not persistent right now

In `modules/mysql-shared/main.tf`, MySQL storage is currently defined with `empty_dir`.

Operational impact:

- MySQL data is ephemeral
- if the MySQL pod is recreated, its data can be lost
- `tenants.sql` will only re-run on a fresh MySQL initialization

For a stable environment, the MySQL deployment should eventually be changed to use persistent storage.

### Tenant application pods are image-driven

The current tenant chart does not define the persistent runtime asset workflow as part of the active design.

Operational impact:

- do not assume you will patch running pods with files
- the stable source of truth for frontend/backend behavior is the image reference in `main.tf`

### Ingress host value is chart-driven by tenant name

Terraform sets `ingress.host`, but the current `ingress.yaml` template uses the tenant name directly for the host.

Operational impact:

- the effective host is currently `<tenant>.local`
- if host naming must change, the chart template should be updated

## 8. Validation after deployment

Run per tenant:

```bash
kubectl get ns kenyaemr-tenant-<tenant>
kubectl get deploy -n kenyaemr-tenant-<tenant>
kubectl get pods -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-backend -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant>
kubectl get svc -n kenyaemr-tenant-<tenant>
kubectl get ingress -n kenyaemr-tenant-<tenant>
kubectl get configmap <tenant>-runtime-config -n kenyaemr-tenant-<tenant> -o yaml
```

If the backend fails to start:

```bash
kubectl describe pod -n kenyaemr-tenant-<tenant> <pod-name>
kubectl logs deploy/<tenant>-backend -n kenyaemr-tenant-<tenant> --tail=200
```

If the frontend fails to start:

```bash
kubectl logs deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant> --tail=200
```

## 9. Rollback model

Rollback is also image-based.

To roll back:

1. set the tenant image back to the previous known-good tag in `main.tf`
2. run:

```bash
terraform plan
terraform apply
```

That causes Kubernetes to roll out the previously known-good image again.
