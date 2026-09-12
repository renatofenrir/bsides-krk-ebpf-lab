variable "upstream_dns" {
  description = "Upstream DNS server (Pi-hole)"
  type        = string
  default     = "192.0.2.168"
}

variable "internal_domain" {
  description = "Internal domain to forward to upstream DNS"
  type        = string
  default     = "example.com"
}

variable "coredns_ip" {
  description = "CoreDNS ClusterIP"
  type        = string
  default     = "10.233.0.3"
}
