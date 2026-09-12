output "gateway_api_crds" {
  description = "Gateway API resources registered, so a failed CRD apply is visible."
  value       = module.gateway_api_crds.applied_resource_keys
}

output "metrics_server_status" {
  value = module.metrics_server.status
}

output "local_path_status" {
  value = module.local_path.status
}

output "storage_class_name" {
  value = var.storage_class_name
}

output "coredns_upstream_dns" {
  value = module.coredns_config.upstream_dns
}

output "monitoring_enabled" {
  value = var.enable_monitoring
}
