resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = var.chart_version
  namespace        = "metrics-server"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "args"
    value = "{--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}"
  }

  set {
    name  = "metrics.enabled"
    value = "true"
  }
}
