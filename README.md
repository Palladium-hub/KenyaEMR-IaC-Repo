# KenyaEMR Kubernetes Multi-Tenant IaC

Terraform-managed multi-tenant deployment of [OpenMRS/KenyaEMR](https://openmrs.atlassian.net/wiki/spaces/docs/pages/189464758/Kubernetes) on AWS EKS.

## What Changed (aws-review branch)

This branch replaces the original local-cluster setup with a fully AWS-managed infrastructure. Here's what was added and changed compared to `main`:

### VPC (new)
- Dedicated VPC (`10.0.0.0/16`) with 3 public and 3 private subnets across `eu-west-3a`, `eu-west-3b`, `eu-west-3c`
- Internet gateway for public subnets, NAT gateway for private subnet outbound access
- Subnets tagged for EKS auto-discovery (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`)
- Module: `modules/vpc/`

### EKS Cluster (new)
- Managed EKS cluster with Kubernetes 1.31
- AL2023 Linux managed node group (`m5.large`, 2 desired / 4 max)
- EKS add-ons: `vpc-cni`, `coredns`, `kube-proxy`
- OIDC provider for IAM Roles for Service Accounts (IRSA)
- Kubernetes and Helm providers authenticate dynamically via `aws eks get-token` (no more `~/.kube/config` dependency)
- Module: `modules/eks/`

### EKS Access Entries (new)
- Configurable cluster admin access for IAM users and roles
- Set in `terraform.tfvars`:
  ```hcl
  cluster_admin_user_arns = [
    "arn:aws:iam::123456789012:user/your-iam-user",
  ]
  cluster_admin_role_arns = [
    "arn:aws:iam::123456789012:role/YourAdminRole",
  ]
  ```
- Uses `AmazonEKSClusterAdminPolicy` with cluster-wide scope
- Node group gets an automatic `EC2_LINUX` access entry
- Files: `variables.tf` (root), `modules/eks/variables.tf`, `modules/eks/main.tf`

### RDS MySQL (new — replaces in-cluster MySQL)
- Amazon RDS MySQL 8.0 (multi-AZ, encrypted, automated backups)
- Replaces the old `modules/mysql-shared/` which ran MySQL in a pod with `emptyDir` storage
- Security group allows inbound 3306 only from EKS node security group
- The RDS endpoint is resolved at apply time and automatically propagated to each tenant's runtime ConfigMap (`<tenant>-runtime-config`) as the JDBC connection URL, and to the backend pod environment variables (`OMRS_CONFIG_CONNECTION_SERVER`). No manual endpoint configuration is needed.
- Module: `modules/rds/`

### AWS Secrets Manager (new — replaces plaintext credentials)
- Per-tenant database credentials stored in Secrets Manager (`kenyaemr/<tenant>/db-credentials`)
- Passwords auto-generated (24 chars) via `random_password`
- Optional 30-day automatic rotation via Lambda (set `rotation_lambda_arn` in tfvars)
- RDS master password managed by AWS (`manage_master_user_password = true`)
- Terraform variables marked `sensitive = true`
- Module: `modules/tenant-secrets/`

### AWS Load Balancer Controller (new — replaces nginx ingress)
- Deployed via Helm into `kube-system` with IRSA
- IAM policy from the [official upstream](https://github.com/kubernetes-sigs/aws-load-balancer-controller)
- Ingress templates updated: `ingressClassName: alb`, path-based routing, no host-based rules
- Each tenant gets its own ALB via `alb.ingress.kubernetes.io/group.name`

### Helm Chart Changes
- Backend deployment: added `containerPort`, resource requests/limits, readiness/liveness probes
- Frontend deployment: added `containerPort`, resource requests/limits, readiness/liveness probes
- Resource defaults configurable via `values.yaml` (`backend.resources`, `frontend.resources`)
- Removed `init-db-job.yaml` (no longer needed with RDS)
- Removed empty `configMap.yaml`
- Removed `timestamp()` force-redeploy hack from Helm release
- Fixed `set` block syntax (individual `set {}` blocks instead of list-of-objects)

### Removed
- `modules/mysql-shared/` — replaced by RDS
- `modules/mysql-shared/init/tenants.sql` — tenant DB/user creation now handled externally
- `charts/kenyaemr-tenant/templates/init-db-job.yaml` — DB restore job no longer needed
- `charts/kenyaemr-tenant/templates/configMap.yaml` — was empty
- Hardcoded credentials throughout

## Architecture

This repo provisions the full stack from scratch in a single `terraform apply`:

- VPC with public/private subnets across 3 AZs (eu-west-3 / Paris)
- EKS cluster with managed AL2023 Linux node group
- Amazon RDS MySQL 8.0 (multi-AZ, encrypted, automated backups)
- AWS Secrets Manager for all database credentials with 30-day rotation
- AWS Load Balancer Controller for ALB-based ingress
- EKS add-ons: VPC CNI, CoreDNS, kube-proxy
- Per-tenant namespaced deployments via Helm

## Modules

| Module | Description |
|--------|-------------|
| `modules/vpc` | VPC, subnets, NAT gateway, route tables, EKS subnet tags |
| `modules/eks` | EKS cluster, node group, OIDC provider, access entries, add-ons, LB controller IAM |
| `modules/rds` | RDS MySQL instance, subnet group, security group |
| `modules/tenant-secrets` | Per-tenant Secrets Manager secrets with rotation |
| `modules/kenyaemr-tenant` | Namespace + Helm release per tenant |

## Tenants

Each tenant gets:
- Dedicated Kubernetes namespace (`kenyaemr-tenant-<name>`)
- OpenMRS backend + frontend deployments with resource limits and health checks
- ALB Ingress with path-based routing (`/openmrs/spa` → frontend, `/openmrs` → backend)
- Isolated database schema on the shared RDS instance
- Dedicated database credentials in Secrets Manager

Current tenants: `mbagathicrh`, `kayolesch`

## Container Images

| Component | Image |
|-----------|-------|
| Backend | `hakeemraj/kenyaemr-backend:latest` |
| Frontend | `hakeemraj/kenyaemr-frontend:latest` |

## EKS Access Entries

Access entries are configured via `terraform.tfvars`. Set the IAM user and role ARNs that should have cluster admin access:

```hcl
# terraform.tfvars
cluster_admin_user_arns = [
  "arn:aws:iam::123456789012:user/your-iam-user",
]

cluster_admin_role_arns = [
  "arn:aws:iam::123456789012:role/YourAdminRole",
]
```

These are defined in:
- `variables.tf` (root) — `cluster_admin_user_arns` and `cluster_admin_role_arns`
- `modules/eks/variables.tf` — passed through to the EKS module
- `modules/eks/main.tf` — creates `aws_eks_access_entry` and `aws_eks_access_policy_association` resources with `AmazonEKSClusterAdminPolicy`

The node group automatically gets an `EC2_LINUX` access entry.

## Requirements

- Terraform >= 1.0
- AWS CLI configured with credentials for account `<account-id>`
- Providers: `hashicorp/aws ~> 5.0`, `hashicorp/kubernetes ~> 2.0`, `hashicorp/helm ~> 2.0`, `hashicorp/random ~> 3.0`, `hashicorp/tls ~> 4.0`

## Usage

```bash
# Deploy everything
terraform init
terraform apply

# Connect kubectl
aws eks update-kubeconfig --name kenyaemr-cluster --region eu-west-3
```

## Configuration

All defaults are set for Paris (eu-west-3). Override via `terraform.tfvars`:

```hcl
aws_region          = "eu-west-3"
cluster_name        = "kenyaemr-cluster"
cluster_version     = "1.31"
vpc_cidr            = "10.0.0.0/16"
node_instance_types = ["m5.large"]
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 4
db_instance_class   = "db.t3.medium"
```

## Adding a New Tenant

1. Add a `tenant-secrets` module block in `main.tf`
2. Add a `kenyaemr-tenant` module block pointing to the secrets output
3. Create the database schema and user on RDS
4. Run `terraform apply`

## RDS Snapshots

On `terraform destroy`, RDS automatically creates a final snapshot named `kenyaemr-mysql-final-snapshot` before deleting the instance. To restore from it later:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier kenyaemr-mysql-restored \
  --db-snapshot-identifier kenyaemr-mysql-final-snapshot \
  --region eu-west-3
```

## Destroy Order

Terraform handles destroy ordering automatically via `depends_on` chains. Tenant workloads and the LB controller are destroyed before access entries and the cluster. If you hit `Unauthorized` errors during destroy (e.g. access entries were manually removed), clean up state first:

```bash
terraform state rm module.mbagathiemr
terraform state rm module.kayoleemr
terraform state rm helm_release.aws_lb_controller
terraform destroy
```

## Reference

- [OpenMRS Kubernetes Deployment Guide](https://openmrs.atlassian.net/wiki/spaces/docs/pages/189464758/Kubernetes)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [AWS Secrets Manager Rotation](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html)
