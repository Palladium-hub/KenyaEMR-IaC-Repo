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

module "coast" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant" 

  tenant_name    = "coast"
  db_schema      = "openmrs_coast"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "coast_user"
  db_password = ""
  backend_image  = "hakeemraj/kenyaemr-backend:multi"
  frontend_image = "hakeemraj/kenyaemr-frontend-ksm:latest"
  oidc_realm     = "coast"
  oidc_client_id = "coast-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/coast"
}

module "eastern" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "eastern"
  db_schema      = "openmrs_eastern"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "eastern_user"
  db_password = ""
  backend_image  = "hakeemraj/kenyaemr-backend:multi"
  frontend_image = "hakeemraj/kenyaemr-frontend:multi"
  oidc_realm     = "eastern"
  oidc_client_id = "eastern-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/eastern"
}

module "nairobi" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant"  

  tenant_name    = "nairobi"
  db_schema      = "openmrs_nairobi"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "nairobi_user"
  db_password = ""
  backend_image  = "hakeemraj/kenyaemr-backend:latest"
  frontend_image = "hakeemraj/kenyaemr-frontend-ksm:latest"
  oidc_realm     = "nairobi"
  oidc_client_id = "nairobi-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/nairobi"
}

module "nyanza" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "nyanza"
  db_schema      = "openmrs_nyanza"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "nyanza_user"
  db_password = ""
  backend_image  = "hakeemraj/kenyaemr-backend:latest"
  frontend_image = "hakeemraj/kenyaemr-frontend-ksm:latest"
  oidc_realm     = "nyanza"
  oidc_client_id = "nyanza-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/nyanza"
}

module "rift" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "rift"
  db_schema      = "openmrs_rift"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "rift_user"
  db_password = ""
  backend_image  = "hakeemraj/kenyaemr-backend:latest"
  frontend_image = "hakeemraj/kenyaemr-frontend-ksm:latest"
  oidc_realm     = "rift"
  oidc_client_id = "rift-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/rift"
}

module "western" {
  source        = "./modules/kenyaemr-tenant"
  chart_path    = "${path.module}/charts/kenyaemr-tenant"

  tenant_name    = "western"
  db_schema      = "openmrs_western"
  db_host        = "mysql.mysql.svc.cluster.local"
  db_user        = "western_user"
  db_password = ""
  backend_image  = "hakeemraj/kenyaemr-backend:latest"
  frontend_image = "hakeemraj/kenyaemr-frontend-ksm:latest"
  oidc_realm     = "western"
  oidc_client_id = "western-spa"
  oidc_issuer    = "https://keycloak.kenyahmis.org/realms/western"
}

# Add more tenants here...

resource "kubernetes_namespace" "hub" {
  metadata {
    name = "hub"
  }
 
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata]
  }
}
 
module "hub" {
  source     = "./modules/kenyaemr-hub"
  namespace  = kubernetes_namespace.hub.metadata[0].name
  chart_path = "${path.module}/charts/kenyaemr-hub"
}
