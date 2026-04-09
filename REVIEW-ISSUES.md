# KenyaEMR Terraform Code Review — Issues

## 1. Hardcoded Credentials in Plaintext

**Severity:** Critical  
**Files:** `modules/mysql-shared/main.tf`, `modules/mysql-shared/init/tenants.sql`, `main.tf`

The MySQL root password (`openmrs`) is set directly in the Deployment spec, and tenant credentials (`kayole_pass`, `mbagathi_pass`) appear in plaintext in both Terraform and SQL.

**Recommendation:**
- Use Kubernetes Secrets to inject passwords into pods.
- Use an external secrets manager (HashiCorp Vault, AWS Secrets Manager, etc.).
- Mark Terraform variables as `sensitive = true`.
- Never commit credentials to version control.

---

## 2. Ephemeral MySQL Storage (`emptyDir`)

**Severity:** Critical  
**File:** `modules/mysql-shared/main.tf`

The MySQL volume uses `empty_dir {}`, meaning all data is lost when the pod restarts or is rescheduled.

**Recommendation:**
- Replace with a `PersistentVolumeClaim` backed by durable storage.
- For production, consider a managed database service (e.g., Amazon RDS) instead of running MySQL in a pod.

---

## 3. No Resource Requests or Limits

**Severity:** High  
**Files:** `modules/mysql-shared/main.tf`, `charts/kenyaemr-tenant/templates/backend-deployment.yaml`, `charts/kenyaemr-tenant/templates/frontend-deployment.yaml`

None of the containers define CPU or memory `requests`/`limits`. This can cause noisy-neighbor issues, OOM kills, or unschedulable pods.

**Recommendation:**
```yaml
resources:
  requests:
    cpu: "250m"
    memory: "512Mi"
  limits:
    cpu: "1"
    memory: "1Gi"
```

---

## 4. No Health Checks (Readiness/Liveness Probes)

**Severity:** High  
**Files:** All deployment templates (MySQL, backend, frontend)

No `readinessProbe` or `livenessProbe` is defined on any container. Kubernetes cannot detect if the application is actually healthy or ready to serve traffic.

**Recommendation:**
```yaml
readinessProbe:
  httpGet:
    path: /openmrs/health
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /openmrs/health
    port: 8080
  initialDelaySeconds: 120
  periodSeconds: 30
```

---

## 5. `timestamp()` Forces Redeployment on Every Plan

**Severity:** Medium  
**File:** `modules/kenyaemr-tenant/main.tf`

The Helm release sets `deployment.forceRedeployTimestamp = timestamp()`, which changes on every `terraform plan`. This causes unnecessary redeployments even when nothing has actually changed.

**Recommendation:**
- Remove the timestamp, or
- Use a hash of the image tags / config values instead so redeployments only happen when inputs change.

---

## 6. Helm `set` Syntax May Be Incompatible

**Severity:** Medium  
**File:** `modules/kenyaemr-tenant/main.tf`

The `helm_release` uses `set` as a list of objects. Depending on the Terraform Helm provider version, this may need to be individual `set {}` blocks:

```hcl
set {
  name  = "tenant.name"
  value = var.tenant_name
}
set {
  name  = "tenant.backendImage"
  value = var.backend_image
}
```

---

## 7. Backend Container Missing `ports` Spec

**Severity:** Low  
**File:** `charts/kenyaemr-tenant/templates/backend-deployment.yaml`

The backend container doesn't declare `containerPort: 8080` even though the Service targets it. While Kubernetes doesn't strictly require it, declaring ports improves clarity and tooling support.

---

## 8. Empty `configMap.yaml` Template

**Severity:** Low  
**File:** `charts/kenyaemr-tenant/templates/configMap.yaml`

This template file is empty. It should either be populated or removed to keep the chart clean.

---

## 9. Missing `FLUSH PRIVILEGES` in Init SQL

**Severity:** Low  
**File:** `modules/mysql-shared/init/tenants.sql`

The init script creates users and grants privileges but doesn't end with `FLUSH PRIVILEGES;`. MySQL typically handles this automatically for DDL statements, but including it explicitly is a safer practice.

---
---

# Recommendations

The following recommendations address the critical issues above and align with the
[OpenMRS Kubernetes deployment guide](https://openmrs.atlassian.net/wiki/spaces/docs/pages/189464758/Kubernetes),
which supports vendor-provided databases and externally managed credentials.

---

## R1. Replace In-Cluster MySQL with Amazon RDS

The current `mysql-shared` module runs MySQL 8.0 inside a pod with ephemeral storage.
This should be replaced with an Amazon RDS MySQL instance managed by Terraform.

Remove `modules/mysql-shared/` entirely and add an RDS module. Example:

```hcl
# modules/rds/main.tf

resource "aws_db_subnet_group" "kenyaemr" {
  name       = "kenyaemr-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "kenyaemr-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "kenyaemr-rds-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "kenyaemr" {
  identifier     = "kenyaemr-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class  # e.g. "db.t3.medium"

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_encrypted     = true

  db_name  = "openmrs"
  username = "admin"

  # Password pulled from Secrets Manager (see R2)
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_id

  db_subnet_group_name   = aws_db_subnet_group.kenyaemr.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = true
  deletion_protection = true
  skip_final_snapshot = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  tags = {
    Project = "KenyaEMR"
  }
}

output "rds_endpoint" {
  value = aws_db_instance.kenyaemr.endpoint
}

output "rds_master_secret_arn" {
  value = aws_db_instance.kenyaemr.master_user_secret[0].secret_arn
}
```

```hcl
# modules/rds/variables.tf

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "eks_node_security_group_id" {
  type = string
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "kms_key_id" {
  type    = string
  default = null
}
```

Then update `main.tf` to point tenants at the RDS endpoint:

```hcl
module "rds" {
  source                     = "./modules/rds"
  vpc_id                     = var.vpc_id
  private_subnet_ids         = var.private_subnet_ids
  eks_node_security_group_id = var.eks_node_security_group_id
}

module "mbagathiemr" {
  source     = "./modules/kenyaemr-tenant"
  chart_path = "${path.module}/charts/kenyaemr-tenant"

  tenant_name = "mbagathicrh"
  db_schema   = "openmrs_mbagathicrh"
  db_host     = module.rds.rds_endpoint
  # credentials from Secrets Manager — see R2
}
```

This aligns with the OpenMRS Kubernetes guide, which explicitly supports
"vendor provided or externally installed database" by disabling the in-chart
MariaDB and supplying an external hostname, port, username, and password.

---

## R2. Store Database Passwords in AWS Secrets Manager

All credentials (root, per-tenant) should live in AWS Secrets Manager, not in
Terraform state or source code.

For the RDS master password, the `manage_master_user_password = true` setting
in R1 already handles this — RDS creates and manages the secret automatically.

For per-tenant database users, create dedicated secrets:

```hcl
# modules/tenant-secrets/main.tf

resource "random_password" "db_password" {
  length  = 24
  special = true
}

resource "aws_secretsmanager_secret" "tenant_db" {
  name        = "kenyaemr/${var.tenant_name}/db-credentials"
  description = "Database credentials for tenant ${var.tenant_name}"
}

resource "aws_secretsmanager_secret_version" "tenant_db" {
  secret_id = aws_secretsmanager_secret.tenant_db.id
  secret_string = jsonencode({
    username = var.db_user
    password = random_password.db_password.result
    dbname   = var.db_schema
    host     = var.db_host
    port     = 3306
  })
}

output "secret_arn" {
  value = aws_secretsmanager_secret.tenant_db.arn
}
```

On the Kubernetes side, use the
[AWS Secrets Store CSI Driver](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html)
to mount secrets into pods as volumes or environment variables, so credentials
never appear in Helm values or Terraform variables.

---

## R3. Configure Password Rotation Every 30 Days

Enable automatic rotation on each Secrets Manager secret.

For the RDS master password (managed by RDS):

```hcl
# RDS manages rotation automatically when manage_master_user_password = true.
# You can customize the rotation schedule:
resource "aws_db_instance" "kenyaemr" {
  # ... (from R1)
  manage_master_user_password            = true
  master_user_secret_rotation_period     = 30  # days
}
```

For per-tenant secrets, set up a Lambda-based rotation:

```hcl
resource "aws_secretsmanager_secret_rotation" "tenant_db" {
  secret_id           = aws_secretsmanager_secret.tenant_db.id
  rotation_lambda_arn = var.rotation_lambda_arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

The rotation Lambda should:
1. Generate a new password.
2. Update the MySQL user via the RDS endpoint.
3. Store the new password in the secret's `AWSCURRENT` stage.

AWS provides a
[generic MySQL rotation template](https://docs.aws.amazon.com/secretsmanager/latest/userguide/reference_available-rotation-templates.html)
that can be deployed as a Lambda function.

---

## R4. Set Resource Requests and Limits on All Pods

Per the OpenMRS Kubernetes guide, the minimum recommended spec per node is
1.5+ GHz CPU and 2+ GB RAM. All containers should declare resource boundaries.

### Backend (OpenMRS)

In `charts/kenyaemr-tenant/templates/backend-deployment.yaml`, add to the
container spec:

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "2"
    memory: "2Gi"
```

OpenMRS backend is a Java application that benefits from generous memory.
The guide notes that the backend can be resource-intensive, especially during
module loading and search indexing.

### Frontend (Nginx)

In `charts/kenyaemr-tenant/templates/frontend-deployment.yaml`:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

The frontend is a lightweight nginx container serving static files. The OpenMRS
guide confirms it is "a very performant service" that rarely needs more resources.

### Make values configurable

Add these to `values.yaml` so they can be tuned per tenant without editing templates:

```yaml
backend:
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "2Gi"

frontend:
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "256Mi"
```

Then reference them in templates:

```yaml
resources:
  {{- toYaml .Values.backend.resources | nindent 12 }}
```

---

## Reference

- [OpenMRS Kubernetes Deployment Guide](https://openmrs.atlassian.net/wiki/spaces/docs/pages/189464758/Kubernetes)
  — Covers architecture, requirements (1.5+ GHz CPU, 2+ GB RAM per node),
  vendor-provided database support, Helm chart configuration, and multi-tenant
  deployment patterns.
- [AWS Secrets Manager CSI Driver](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html)
- [AWS Secrets Manager Rotation Templates](https://docs.aws.amazon.com/secretsmanager/latest/userguide/reference_available-rotation-templates.html)
