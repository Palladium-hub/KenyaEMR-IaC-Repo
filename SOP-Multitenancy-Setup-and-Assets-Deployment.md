# KenyaEMR Multi-Tenancy Deployment SOP

## Image-Based Environment Setup and Tenant Operations

This SOP defines the active operating model for this repository.

It assumes:

- tenant changes are delivered through container images
- Terraform and Helm are the deployment mechanism
- multitenancy is enforced by namespace, ingress, and database isolation
- runtime file-copy deployment is not part of the standard process

## 1. Purpose

Use this SOP to:

- prepare a Kubernetes environment for KenyaEMR multitenancy
- add new tenants safely
- release backend and frontend changes using image tags
- validate and roll back deployments

## 1.1 Terminology and Abbreviations

- **IaC (Infrastructure as Code)**: Managing infrastructure through version-controlled code instead of manual setup.
- **K8s (Kubernetes)**: The container orchestration platform used to run this environment.
- **Tenant**: One isolated KenyaEMR customer/site deployment inside the shared platform.
- **Multitenancy**: Running multiple tenant environments on one shared cluster while isolating their workloads and data.
- **Namespace**: A Kubernetes boundary used to isolate one tenant's resources from another.
- **Pod**: The smallest runnable unit in Kubernetes, containing one or more containers.
- **Deployment**: A Kubernetes resource that manages pods, updates, and restarts.
- **Service**: A stable internal network endpoint used to expose a pod or deployment inside the cluster.
- **Ingress**: A Kubernetes resource that routes external HTTP traffic to tenant services.
- **IngressClass**: The controller class that owns and processes an ingress resource, for example `nginx`.
- **ConfigMap**: A Kubernetes object used to inject non-secret configuration into containers.
- **Helm**: The package manager used here to render and install tenant Kubernetes manifests.
- **Chart**: A Helm package containing templates and values for an application.
- **Release**: One installed instance of a Helm chart. In this repo, each tenant is one Helm release.
- **Terraform**: The tool used to create and update the Kubernetes and Helm resources defined in this repo.
- **kubeconfig**: The local Kubernetes client configuration file, usually `~/.kube/config`.
- **Image**: A container image that packages the backend or frontend application.
- **Image Tag**: The version label on a container image, for example `v1`, `latest`, or `north-v2`.
- **Immutable Image Deployment**: Releasing changes by publishing a new image and rolling out that image, instead of copying files into running containers.
- **Rollout**: The Kubernetes process of replacing old pods with new ones after a deployment change.
- **DB (Database)**: The tenant's MySQL database schema used by the backend.
- **Schema**: The logical database owned by a specific tenant inside the shared MySQL server.
- **Runtime Configuration**: The tenant-specific application settings provided to the backend at runtime, in this repo through `runtime.properties`.
- **PVC (PersistentVolumeClaim)**: A Kubernetes request for persistent storage.
- **PV (PersistentVolume)**: The actual cluster storage volume bound to a PVC.
- **StorageClass**: The storage provisioner policy used when Kubernetes creates persistent storage.

## 2. Active deployment model

This repo uses an image-only release model.

That means:

- backend changes should be baked into the backend image
- frontend SPA changes should be baked into the frontend image
- deployment happens by updating image references in Terraform and applying
- running pod files are not the source of truth

The source of truth is:

- infrastructure: Terraform
- Kubernetes manifests: Helm templates
- application content: published container images

## 3. Environment prerequisites

### Operator workstation

Required tools:

- `terraform`
- `kubectl`
- `helm`

Required access:

- a valid kubeconfig at `~/.kube/config`
- permission to create resources in the target cluster

Verify before deployment:

```bash
pwd
terraform version
kubectl version --client
helm version
kubectl config current-context
```

### Cluster prerequisites

The target cluster must have:

- a working Kubernetes control plane
- a functioning ingress controller for class `nginx`
- cluster networking that allows access to tenant ingress endpoints

Verify:

```bash
kubectl get nodes
kubectl get ingressclass
kubectl get ns
```

## 4. First-time local environment setup for MicroK8s

Use this only when bootstrapping a new local MicroK8s machine.

1. Install MicroK8s if needed:

```bash
sudo snap install microk8s --classic
```

2. Start and verify readiness:

```bash
sudo microk8s stop
sudo microk8s start
microk8s status --wait-ready
```

3. Enable required addons:

```bash
microk8s enable dns hostpath-storage ingress
microk8s kubectl get ingressclass
```

4. Configure kubeconfig for the current user:

```bash
mkdir -p ~/.kube
sudo microk8s config > ~/.kube/config
sudo chown -R "$(id -un):$(id -gn)" ~/.kube
chmod 600 ~/.kube/config
```

5. Confirm `kubectl` points to the expected cluster:

```bash
kubectl config current-context
kubectl get nodes
```

## 5. Multitenancy model in this repo

Each tenant is isolated in three ways.

### Namespace isolation

Each tenant gets its own namespace:

- `kenyaemr-tenant-<tenant>`

### Application isolation

Each tenant gets its own workloads:

- backend deployment: `<tenant>-backend`
- frontend deployment: `<tenant>-frontend`
- backend service: `<tenant>-backend`
- frontend service: `<tenant>-frontend`
- runtime configmap: `<tenant>-runtime-config`
- ingress: tenant-specific routing

### Database isolation

All tenants share one MySQL server but do not share schemas.

Per tenant:

- one schema, for example `openmrs_kayolesch`
- one DB user, for example `kayole_user`
- one DB password

The backend uses tenant-specific DB settings from the runtime configmap.

## 6. Naming conventions to keep consistent

Use the same tenant identity across all files.

Example for tenant `north`:

- Terraform module label: `module "north"`
- tenant name: `north`
- namespace: `kenyaemr-tenant-north`
- backend deployment: `north-backend`
- frontend deployment: `north-frontend`
- DB schema: `openmrs_north`
- DB user: `north_user`
- host: `north.local`

Do not mix names across layers. Tenant name, namespace, host, DB schema, and deployment names must align.

## 7. Files you edit for multitenancy

Primary files:

- `main.tf`
- `modules/mysql-shared/init/tenants.sql`

Secondary files, only when changing platform behavior:

- `modules/kenyaemr-tenant/variables.tf`
- `charts/kenyaemr-tenant/templates/*.yaml`
- `charts/kenyaemr-tenant/values.yaml`

## 8. Adding a new tenant

### Step 1: Define tenant inputs

Choose and write down:

- `tenant_name`
- `db_schema`
- `db_user`
- `db_password`
- `backend_image`
- `frontend_image`

Example:

- `tenant_name = "north"`
- `db_schema = "openmrs_north"`
- `db_user = "north_user"`
- `db_password = "north_pass"`

### Step 2: Add tenant DB SQL in source control

Edit `modules/mysql-shared/init/tenants.sql` and add:

```sql
-- north Tenant
CREATE DATABASE IF NOT EXISTS openmrs_north CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'north_user'@'%' IDENTIFIED BY 'north_pass';
GRANT ALL PRIVILEGES ON openmrs_north.* TO 'north_user'@'%';
```

Important:

- this SQL is only auto-run when MySQL initializes a fresh data directory
- if MySQL is already running with existing data, you must create the schema and user manually in the live MySQL instance

### Step 3: If MySQL is already running, create the DB manually

Because the current repo deploys MySQL in the `default` namespace, resolve the pod dynamically and run the SQL there.

```bash
DB_SCHEMA="openmrs_north"
DB_USER="north_user"
DB_PASS="north_pass"
MYSQL_POD=$(kubectl get pod -n default -l app=mysql -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n default "$MYSQL_POD" -- mysql -uroot -popenmrs -e "
CREATE DATABASE IF NOT EXISTS ${DB_SCHEMA} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_SCHEMA}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;"
```

Verify:

```bash
kubectl exec -n default "$MYSQL_POD" -- mysql -uroot -popenmrs -e "SHOW DATABASES LIKE 'openmrs_north';"
```

### Step 4: Add the tenant module in `main.tf`

Add a new module block similar to:

```hcl
module "north" {
  source     = "./modules/kenyaemr-tenant"
  chart_path = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "north"
  db_schema      = "openmrs_north"
  db_host        = "mysql.default.svc.cluster.local"
  db_user        = "north_user"
  db_password    = "north_pass"
  backend_image  = "your-registry/kenyaemr-backend:north-v1"
  frontend_image = "your-registry/kenyaemr-frontend:north-v1"
}
```

### Step 5: Deploy

```bash
terraform init
terraform plan
terraform apply
```

### Step 6: Validate the new tenant

```bash
kubectl get ns kenyaemr-tenant-north
kubectl get deploy -n kenyaemr-tenant-north
kubectl get pods -n kenyaemr-tenant-north
kubectl get ingress -n kenyaemr-tenant-north
kubectl rollout status deploy/north-backend -n kenyaemr-tenant-north
kubectl rollout status deploy/north-frontend -n kenyaemr-tenant-north
```

## 9. Releasing changes for an existing tenant

This is the standard release path.

### Step 1: Build and publish images

Do this in your application repos or CI pipeline:

- build the new backend image
- build the new frontend image
- push both images to your registry

### Step 2: Update image tags in `main.tf`

Change the tenant module values:

- `backend_image`
- `frontend_image`

Example:

```hcl
backend_image  = "your-registry/kenyaemr-backend:north-v2"
frontend_image = "your-registry/kenyaemr-frontend:north-v2"
```

### Step 3: Apply the release

```bash
terraform plan
terraform apply
```

### Step 4: Watch rollout

```bash
kubectl rollout status deploy/north-backend -n kenyaemr-tenant-north
kubectl rollout status deploy/north-frontend -n kenyaemr-tenant-north
```

## 10. Ingress and host setup

The current chart routes traffic using tenant hosts in this format:

- `<tenant>.local`

That means your environment must resolve those hostnames to the cluster ingress endpoint.

For local testing, update `/etc/hosts` or your local DNS with entries like:

- `<cluster-ip> north.local`
- `<cluster-ip> kayolesch.local`
- `<cluster-ip> mbagathicrh.local`

Then access:

- `http://north.local/openmrs`
- `http://north.local/openmrs/spa`

## 11. Validation checklist after any deployment

Run these checks for each tenant you changed:

```bash
kubectl get ns kenyaemr-tenant-<tenant>
kubectl get deploy -n kenyaemr-tenant-<tenant>
kubectl get pods -n kenyaemr-tenant-<tenant>
kubectl get svc -n kenyaemr-tenant-<tenant>
kubectl get ingress -n kenyaemr-tenant-<tenant>
kubectl get configmap <tenant>-runtime-config -n kenyaemr-tenant-<tenant> -o yaml
kubectl rollout status deploy/<tenant>-backend -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant>
```

Backend diagnostics:

```bash
kubectl logs deploy/<tenant>-backend -n kenyaemr-tenant-<tenant> --tail=200
kubectl describe pod -n kenyaemr-tenant-<tenant> <pod-name>
```

Frontend diagnostics:

```bash
kubectl logs deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant> --tail=200
```

## 12. Rollback procedure

Rollback is image-based.

1. Change the tenant's image tag in `main.tf` back to the previous known-good version.
2. Run:

```bash
terraform plan
terraform apply
```

3. Confirm rollout returns to healthy state:

```bash
kubectl rollout status deploy/<tenant>-backend -n kenyaemr-tenant-<tenant>
kubectl rollout status deploy/<tenant>-frontend -n kenyaemr-tenant-<tenant>
```

## 13. Important current constraints in this repo

### MySQL storage is currently ephemeral

`modules/mysql-shared/main.tf` uses `empty_dir` for MySQL storage.

Impact:

- DB data is not durable across pod recreation
- if the MySQL pod is rescheduled, data may be lost

For production-grade use, replace this with a persistent volume claim.

### Tenant hostnames are currently hardcoded by tenant name in the chart

The ingress template currently uses the tenant name to form the host.

Impact:

- the active host format is `<tenant>.local`
- if you want a different domain, update the chart template

### Image references are the release control point

Because this SOP assumes image-only deployment:

- the correct place to change behavior is the image tag in `main.tf`
- avoid treating running pod files as the deployment source of truth

## 14. Golden operational order

For a stable environment, use this order:

1. Prepare cluster and kubeconfig
2. Confirm ingress controller and host resolution
3. Add or update tenant database definitions
4. Add or update tenant image references in `main.tf`
5. Run `terraform plan`
6. Run `terraform apply`
7. Validate backend, frontend, ingress, and DB connectivity
8. Roll back by reverting image tags if needed
