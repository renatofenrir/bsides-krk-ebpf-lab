terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.99.0"
    }
  }

}

provider "proxmox" {
  endpoint = var.pm_endpoint
  username = var.pm_user
  password = var.pm_password
  insecure = true
}
