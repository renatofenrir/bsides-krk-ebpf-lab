variable "kube_context" {
  description = <<-EOT
    Kubectl context for the helm/kubernetes/kubectl providers.

    Deliberately NOT "bifrost-prod". The fetch-kubeconfig step renames the
    context to this value precisely so that a components apply run from the
    wrong directory cannot find a prod context to attach to.
  EOT
  type        = string
  default     = "bsides-krk-demo"
}

variable "kube_config_path" {
  description = "Path to the kubeconfig holding the context above."
  type        = string
  default     = "~/.kube/config"
}

variable "storage_class_name" {
  description = "Name of the default StorageClass the lab provisions."
  type        = string
  default     = "local-path"
}

variable "local_path_dir" {
  description = "On-node directory backing the local-path StorageClass."
  type        = string
  default     = "/opt/local-path-provisioner"
}

variable "upstream_dns" {
  description = "Internal resolver for the example.com zone."
  type        = string
  default     = "192.0.2.168"
}

variable "internal_domain" {
  description = "Internal domain forwarded to upstream_dns."
  type        = string
  default     = "example.com"
}

variable "enable_monitoring" {
  description = <<-EOT
    Install kube-prometheus-stack.

    OFF by default. On a two-node lab it is the heaviest thing in the repo,
    Prometheus alone wants ~2Gi, and nothing in Phases 1-3 reads from it --
    the observability story is told through Hubble and tetra, not Grafana.
    Turn it on only if the talk grows a metrics segment.
  EOT
  type        = bool
  default     = false
}

variable "grafana_password" {
  description = "Grafana admin password. Only used when enable_monitoring is true."
  type        = string
  sensitive   = true
  default     = "admin"
}
