provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}

module "mysql_shared" {
  source = "./modules/mysql-shared"
}

module "keycloak" {
  source = "./modules/keycloak"
}

#module "tenants" {
#  for_each = var.tenants

#  source     = "./modules/kenyaemr-tenant"
#  chart_path = "${path.module}/charts/kenyaemr-tenant"

#  tenant_name    = each.key
#  db_schema      = each.value.db_schema
#  db_host        = each.value.db_host
#  db_user        = each.value.db_user
#  db_password    = each.value.db_password
#  backend_image  = each.value.backend_image
#  frontend_image = each.value.frontend_image
#  oidc_realm     = each.value.oidc_realm
#  oidc_client_id = each.value.oidc_client_id
#  oidc_issuer    = each.value.oidc_issuer
#}

resource "kubernetes_namespace" "hub" {
  for_each = var.hubs

  metadata {
    name = each.value.namespace
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes  = [metadata]
  }
}

module "hub" {
  for_each = var.hubs

  source      = "./modules/kenyaemr-hub"
  namespace   = kubernetes_namespace.hub[each.key].metadata[0].name
  chart_path  = "${path.module}/charts/kenyaemr-hub"
  hub_name    = each.key
  values_file = each.value.values_file
}
