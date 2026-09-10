#!/usr/bin/env bash
# Phase 1, step 1: clone three VMs on Proxmox.
#
# Reads nothing from the prod repo and writes state to ./terraform/terraform.tfstate.
set -euo pipefail
cd "$(dirname "$0")/../terraform"

: "${TF_VAR_pm_user:?export TF_VAR_pm_user, e.g. root@pam}"
: "${TF_VAR_pm_password:?export TF_VAR_pm_password}"

terraform init
terraform plan -out=lab.tfplan

cat <<'WARN'

------------------------------------------------------------------------
Read the plan above before continuing.

Expect exactly: Plan: 3 to add, 0 to change, 0 to destroy.

ANY destroy, or any hostname containing "bifrost-prod", means this is
pointed at the wrong thing. Ctrl-C now.
------------------------------------------------------------------------

WARN
read -rp "Type 'apply' to continue: " confirm
[[ "$confirm" == "apply" ]] || { echo "Aborted."; exit 1; }

terraform apply lab.tfplan
terraform output
