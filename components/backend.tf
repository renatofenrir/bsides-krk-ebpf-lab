# Same MinIO backend as prod, DIFFERENT key. See vms/backend.tf for the
# offline escape hatch.
terraform {
  backend "s3" {
    bucket = "bifrost-minio-bucket"
    key    = "bsides-krk-lab/components/terraform.tfstate"

    endpoints = {
      s3 = "http://192.0.2.59:9000"
    }

    region                      = "bifrost-prox"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
    skip_requesting_account_id  = true
  }
}
