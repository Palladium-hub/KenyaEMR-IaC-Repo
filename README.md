# KenyaEMR Kubernetes Multi-Tenant IaC

Terraform-managed multi-tenant deployment of [OpenMRS/KenyaEMR](https://openmrs.atlassian.net/wiki/spaces/docs/pages/189464758/Kubernetes) on AWS EKS.

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
| Backend | `openmrs/openmrs-reference-application-3-backend:nightly-core-2.8` |
| Frontend | `openmrs/openmrs-reference-application-3-frontend:nightly-core-2.8` |

## EKS Access Entries

| Principal | Type | Policy |
|-----------|------|--------|
| Node group role | EC2_LINUX | — |
| `arn:aws:iam::<account-id>:user/maccli` | STANDARD | AmazonEKSClusterAdminPolicy |
| `arn:aws:iam::<account-id>:role/Admin` | STANDARD | AmazonEKSClusterAdminPolicy |

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
