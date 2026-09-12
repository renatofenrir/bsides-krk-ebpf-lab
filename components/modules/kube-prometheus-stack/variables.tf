variable "chart_version" {
  description = "kube-prometheus-stack helm chart version"
  type        = string
  default     = "87.18.0"
}

variable "namespace" {
  description = "Namespace to deploy kube-prometheus-stack"
  type        = string
  default     = "kube-prometheus-stack"
}

variable "grafana_hostname" {
  description = "Grafana ingress hostname"
  type        = string
  default     = "grafana.k8s-prod-v4.example.com"
}

variable "grafana_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "grafana_persistence_enabled" {
  description = "Enable Grafana persistence"
  type        = bool
  default     = true
}

variable "prometheus_retention" {
  description = "Prometheus data retention period"
  type        = string
  default     = "7d"
}

variable "prometheus_retention_size" {
  description = "Prometheus size-based retention cap (e.g. \"32GiB\"), the actual backstop against filling the PVC as scrape volume grows over time. Leave real headroom below prometheus_storage_size -- compaction needs scratch space. Empty string disables size-based retention (time-based only)"
  type        = string
  default     = ""
}

variable "prometheus_storage_enabled" {
  description = "Enable Prometheus persistent storage"
  type        = bool
  default     = true
}

variable "prometheus_storage_size" {
  description = "Prometheus PVC size"
  type        = string
  default     = "20Gi"
}

variable "storage_class_name" {
  description = "StorageClass for persistent volumes"
  type        = string
  default     = "synology-iscsi-storage"
}

variable "alertmanager_enabled" {
  description = "Enable Alertmanager"
  type        = bool
  default     = false
}

variable "alertmanager_telegram_bot_token" {
  description = "Telegram bot token for Alertmanager notifications. When null, Alertmanager keeps the chart's default (routes everything to the no-op 'null' receiver)"
  type        = string
  sensitive   = true
  default     = null
}

variable "alertmanager_telegram_chat_id" {
  description = "Telegram chat ID (use a negative number for group chats) for Alertmanager notifications. Must be a number — Alertmanager's config schema requires chat_id as int64, not a string"
  type        = number
  sensitive   = true
  default     = null
}

variable "node_exporter_rapl_enabled" {
  description = "Enable node-exporter's RAPL collector for host power draw metrics. Requires Intel RAPL or AMD amd_energy kernel support on the node"
  type        = bool
  default     = true
}

variable "electricity_price_pln_per_kwh" {
  description = "Electricity price in PLN per kWh, used by the energy cost estimate dashboard"
  type        = number
  default     = 1.10
}
