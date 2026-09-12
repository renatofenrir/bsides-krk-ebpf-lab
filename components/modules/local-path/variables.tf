variable "chart_version" {
  description = "local-path-provisioner helm chart version"
  type        = string
  default     = null
}

variable "storage_class_name" {
  description = "Name of the StorageClass to create"
  type        = string
  default     = "local-path-nvme"
}

variable "default_path" {
  description = "Default path on node for local storage"
  type        = string
  default     = "/mnt/nvme/local-path"
}

variable "path_pattern" {
  description = "Path pattern for volume directories"
  type        = string
  default     = "$${.node.name}/$${.claim.namespace}/$${.claim.name}"
}

variable "is_default" {
  description = "Whether this StorageClass is the default"
  type        = bool
  default     = false
}

variable "node_label_key" {
  description = "Node label key to restrict provisioner to specific nodes"
  type        = string
  default     = "nvidia.com/gpu.present"
}

variable "node_label_values" {
  description = "Node label values to restrict provisioner to specific nodes"
  type        = list(string)
  default     = ["true"]
}
