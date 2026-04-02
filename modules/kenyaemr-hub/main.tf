resource "helm_release" "hub_landing" {
  name       = "hub"
  namespace  = var.namespace
  replace    =true
  chart      = var.chart_path
  version    = "0.1.0"

  values = [
    file("${path.module}/../../charts/kenyaemr-hub/values.yaml")
  ]

  set = [
    {
      name  = "deployment.forceRedeployTimestamp"
      value = timestamp()
    }
  ]
}
