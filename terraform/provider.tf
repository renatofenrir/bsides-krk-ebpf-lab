terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.99.0"
    }
  }

  # State is LOCAL on purpose.
  #
  # The prod bootstrapper keeps state in MinIO at 192.0.2.59:9000. This lab
  # deliberately does not, for two reasons:
  #
  #   1. Isolation. There is no shared key that a careless `terraform apply`
  #      here could ever write into bifrost-prod/{vms,components}/.
  #   2. Conference reality. If the venue network cannot reach 192.0.2.59, a
  #      remote backend turns "rebuild the lab" into "cannot even plan".
  #
  # To use MinIO anyway, uncomment below and pick a key that is NOT under
  # bifrost-prod/.
  #
  # backend "s3" {
  #   bucket = "bifrost-minio-bucket"
  #   key    = "bsides-krk-lab/vms/terraform.tfstate"
  #   endpoints = { s3 = "http://192.0.2.59:9000" }
  #   region                      = "bifrost-prox"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  #   skip_requesting_account_id  = true
  # }
}

provider "proxmox" {
  endpoint = var.pm_endpoint
  username = var.pm_user
  password = var.pm_password
  insecure = true
}
