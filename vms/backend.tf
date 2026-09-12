# Mirrors the prod bootstrapper's MinIO-as-S3 backend, with a DIFFERENT key.
#
# `bsides-krk-lab/`, never `bifrost-prod/`. Sharing a prefix with prod is the
# one mistake in this repo that could not be undone.
#
# Credentials come from -backend-config at init time, exactly as in prod:
#   terraform init -backend-config=access_key=$AWS_ACCESS_KEY_ID \
#                  -backend-config=secret_key=$AWS_SECRET_ACCESS_KEY
#
# OFFLINE ESCAPE HATCH: if 192.0.2.59 is unreachable (venue network, MinIO
# down) you cannot even run `terraform plan` against a remote backend. Delete
# this file and state falls back to a local tfstate. For a disposable lab that
# is a perfectly good answer -- `make up-local` does exactly this.
terraform {
  backend "s3" {
    bucket = "bifrost-minio-bucket"
    key    = "bsides-krk-lab/vms/terraform.tfstate"

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
