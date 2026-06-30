terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket = "kilifi-wal-archive-prod"
    key    = "terraform/tenants/mtondiad/terraform.tfstate"
    region = "af-south-1"
  }
}