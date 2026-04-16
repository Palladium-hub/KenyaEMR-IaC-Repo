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

  set {
    name  = "tenant.name"
    value = var.tenant_name
  }

  set {
    name  = "tenant.backendImage"
    value = var.backend_image
  }

  set {
    name  = "tenant.frontendImage"
    value = var.frontend_image
  }

  set {
    name  = "tenant.dbHost"
    value = var.db_host
  }

  set {
    name  = "tenant.dbSchema"
    value = var.db_schema
  }

  set {
    name  = "tenant.dbUser"
    value = var.db_user
  }

  set_sensitive {
    name  = "tenant.dbPassword"
    value = var.db_password
  }

  set {
    name  = "ingress.enabled"
    value = "true"
  }

  set {
    name  = "ingress.host"
    value = "${var.tenant_name}.local"
  }
}
