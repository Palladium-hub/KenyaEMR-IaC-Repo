resource "kubernetes_namespace" "tenant" {
  metadata {
    name = "kenyaemr-tenant-${var.tenant_name}"
  }
}

resource "helm_release" "kenyaemr" {
  name       = var.tenant_name
  namespace  = kubernetes_namespace.tenant.metadata[0].name
  chart      = var.chart_path
  version    = "0.1.0"
  timeout    = 7200

  set = [
    {
      name  = "tenant.name"
      value = var.tenant_name
    },
    {
      name  = "tenant.backendImage"
      value = var.backend_image
    },
    {
      name  = "tenant.frontendImage"
      value = var.frontend_image
    },
    {
      name  = "tenant.dbHost"
      value = var.db_host
    },
    {
      name  = "tenant.dbSchema"
      value = var.db_schema
    },
    {
      name  = "tenant.dbUser"
      value = var.db_user
    },
    {
      name  = "tenant.dbPassword"
      value = var.db_password
    },
    {
      name  = "ingress.enabled"
      value = "true"
    },
    {
      name  = "ingress.host"
      value = "${var.tenant_name}.local"
    },
    {
      name  = "tenant.oidc.clientId"
      value = var.oidc_client_id
    },
    {
      name  = "tenant.oidc.issuer"
      value = var.oidc_issuer
    },
    {
      name  = "tenant.oidc.scope"
      value = var.oidc_scope
    },
    {
      name  = "deployment.forceRedeployTimestamp"
      value = timestamp()
    }
  ]
}
