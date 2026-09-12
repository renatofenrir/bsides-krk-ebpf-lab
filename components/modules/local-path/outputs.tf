output "status" {
  value = helm_release.local_path_provisioner.status
}

# output "storage_class_name" {
#   value = kubernetes_storage_class.local_path.metadata[0].name
# }
