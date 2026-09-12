output "applied_resource_keys" {
  value = keys(kubectl_manifest.gateway_api)
}
