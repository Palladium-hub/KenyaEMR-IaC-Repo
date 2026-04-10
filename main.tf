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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# --- VPC ---

module "vpc" {
  source             = "./modules/vpc"
  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

# --- EKS Cluster + Node Group + Access Entries ---

module "eks" {
  source              = "./modules/eks"
  cluster_name        = var.cluster_name
  cluster_version     = var.cluster_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# --- AWS Load Balancer Controller (Helm) ---

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.11.0"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.lb_controller_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks]
}

# --- RDS (replaces in-cluster MySQL) ---

module "rds" {
  source                     = "./modules/rds"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id
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

  depends_on = [module.eks]
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

  depends_on = [module.eks]
}

# Add more tenants here...
