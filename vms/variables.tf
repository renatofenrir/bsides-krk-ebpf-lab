variable "pm_endpoint" {
  description = "Proxmox API endpoint."
  type        = string
  default     = "https://192.168.0.140:8006/"
}

variable "pm_user" {
  description = "Proxmox user, e.g. root@pam. Set via TF_VAR_pm_user."
  type        = string
  sensitive   = true
}

variable "pm_password" {
  description = "Proxmox password. Set via TF_VAR_pm_password, never in tfvars."
  type        = string
  sensitive   = true
}

variable "template_vm_id" {
  description = <<-EOT
    VMID of the plain Ubuntu template to clone (the standard one, NOT the
    NVIDIA-baked template -- this lab has no GPU nodes).
    ACTION REQUIRED: confirm this matches your Proxmox before the first apply.
  EOT
  type        = number
}

variable "ssh_public_key" {
  description = <<-EOT
    SSH public key injected into the ubuntu user via cloud-init. This is the
    CI key: its private half is the SSH_PRIVATE_KEY File variable that every
    SSH step in the pipeline authenticates with.
  EOT
  type        = string
}

variable "extra_ssh_public_keys" {
  description = <<-EOT
    Additional public keys for the ubuntu user, one per line -- e.g. a personal
    key for logging in during the talk. A newline-separated string rather than
    a list so an unset TF_VAR_extra_ssh_public_keys is simply empty instead of
    an HCL parse error.
  EOT
  type        = string
  default     = ""
}

variable "proxmox_node" {
  description = <<-EOT
    Which Proxmox host carries the lab VMs.

    node_name FORCES REPLACEMENT when it changes. That is harmless here (the
    lab is disposable) but it is exactly what nearly destroyed etcd quorum in
    the prod repo on 2026-08-26. If you migrate a lab VM by hand in the
    Proxmox UI, reflect it here or the next apply proposes a rebuild.
  EOT
  type        = string
  default     = "sleipnir"
}

variable "network_bridge" {
  description = "Proxmox bridge. vnet1 is the SDN vnet the prod cluster uses."
  type        = string
  default     = "vnet1"
}

variable "datastore_id" {
  description = <<-EOT
    Datastore for the root disks. local-lvm on purpose: every VM freeze on
    2026-08-26 hit a guest whose ROOT disk was on the Synology iSCSI LUN, and
    a lab that wedges mid-talk is worse than useless.
  EOT
  type        = string
  default     = "local-lvm"
}

variable "dns_server" {
  description = "Internal DNS (example.com resolver)."
  type        = string
  default     = "192.0.2.168"
}

variable "gateway_ip" {
  description = "Default gateway for the lab subnet."
  type        = string
  default     = "10.1.1.1"
}

variable "master_ip" {
  description = <<-EOT
    Control-plane IP. 10.1.1.40 matches the previous BSides demo cluster.
    ACTION REQUIRED: confirm .40-.41 are free before applying. Prod holds
    .50-.52 (masters), .60-.64 (workers) and .90-.93 (GPU).
  EOT
  type        = string
  default     = "10.1.1.40"
}

variable "worker_ips" {
  description = <<-EOT
    Worker IPs, in order. ONE worker by default -- the control plane is
    untainted and carries workloads too, which keeps the cluster at two VMs
    while still giving Hubble cross-node flows to draw.

    Adding an entry here provisions another worker; remember to add it to
    inventory/inventory.ini as well, then use `make scale` (Kubespray
    scale.yml) rather than a full cluster.yml re-run.
  EOT
  type        = list(string)
  default     = ["10.1.1.41"]
}
