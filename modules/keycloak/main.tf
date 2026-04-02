resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = "keycloak"
  }
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  namespace  = kubernetes_namespace.keycloak.metadata[0].name

  chart      = "${path.root}/charts/keycloak"  # local chart path
  values     = [file("${path.module}/values.yaml")]
}
