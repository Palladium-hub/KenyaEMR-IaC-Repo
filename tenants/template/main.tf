provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}

module "tenant" {
  source         = "../../modules/kenyaemr-tenant"
  chart_path     = "../../charts/kenyaemr-tenant"

  tenant_name    = var.tenant_name
  db_schema      = var.db_schema
  db_host        = var.db_host
  db_user        = var.db_user
  db_password    = var.db_password
  backend_image  = var.backend_image
  frontend_image = var.frontend_image
  oidc_realm     = var.oidc_realm
  oidc_client_id = var.oidc_client_id
  oidc_issuer    = var.oidc_issuer
}