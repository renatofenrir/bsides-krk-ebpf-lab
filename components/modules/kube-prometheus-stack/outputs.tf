output "status" {
  value = helm_release.kube_prometheus_stack.status
}

output "grafana_hostname" {
  value = var.grafana_hostname
}
