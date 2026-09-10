output "master_ip" {
  description = "Control-plane IP -- feed this to cilium's k8sServiceHost."
  value       = var.master_ip
}

output "worker_ips" {
  value = var.worker_ips
}

output "all_ips" {
  description = "Every lab node, for ansible connectivity checks."
  value       = concat([var.master_ip], var.worker_ips)
}

output "inventory_preview" {
  description = "Sanity-check that this matches ansible/inventory.ini."
  value       = <<-EOT
    [kube_control_plane]
    k8s-master-0-bsides-krk-demo ansible_host=${var.master_ip}

    [kube_node]
    ${join("\n    ", [for i, ip in var.worker_ips : "k8s-worker-${i}-bsides-krk-demo ansible_host=${ip}"])}
  EOT
}
