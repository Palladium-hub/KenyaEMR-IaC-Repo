terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "aws" {}

# --- RDS (replaces in-cluster MySQL) ---

module "rds" {
  source                     = "./modules/rds"
  vpc_id                     = var.vpc_id
  private_subnet_ids         = var.private_subnet_ids
  eks_node_security_group_id = var.eks_node_security_group_id
  db_instance_class          = var.db_instance_class
  kms_key_id                 = var.kms_key_id
}

# --- Tenant secrets (Secrets Manager + 30-day rotation) ---

module "mbagathi_secrets" {
  source              = "./modules/tenant-secrets"
  tenant_name         = "mbagathicrh"
  db_user             = "mbagathi_user"
  db_schema           = "openmrs_mbagathicrh"
  db_host             = module.rds.rds_address
  rotation_lambda_arn = var.rotation_lambda_arn
}

module "kayole_secrets" {
  source              = "./modules/tenant-secrets"
  tenant_name         = "kayolesch"
  db_user             = "kayole_user"
  db_schema           = "openmrs_kayolesch"
  db_host             = module.rds.rds_address
  rotation_lambda_arn = var.rotation_lambda_arn
}

# --- Tenant deployments ---

module "mbagathiemr" {
  source     = "./modules/kenyaemr-tenant"
  chart_path = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "mbagathicrh"
  db_schema      = "openmrs_mbagathicrh"
  db_host        = module.rds.rds_address
  db_user        = "mbagathi_user"
  db_password    = module.mbagathi_secrets.db_password
  backend_image  = "openmrs/openmrs-reference-application-3-backend:nightly-core-2.8"
  frontend_image = "openmrs/openmrs-reference-application-3-frontend:nightly-core-2.8"
}

module "kayoleemr" {
  source     = "./modules/kenyaemr-tenant"
  chart_path = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "kayolesch"
  db_schema      = "openmrs_kayolesch"
  db_host        = module.rds.rds_address
  db_user        = "kayole_user"
  db_password    = module.kayole_secrets.db_password
  backend_image  = "openmrs/openmrs-reference-application-3-backend:nightly-core-2.8"
  frontend_image = "openmrs/openmrs-reference-application-3-frontend:nightly-core-2.8"
}

# Add more tenants here...
