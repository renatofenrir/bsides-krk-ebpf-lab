# vms/ — Terraform: the two Proxmox VMs

Creates the lab's virtual machines on Proxmox by cloning an Ubuntu template.
Nothing Kubernetes-related happens here; that's Kubespray's job
([`../inventory/`](../inventory/)).

| VM | IP | Role |
|---|---|---|
| `k8s-master-0-bsides-krk-demo` | `10.1.1.40` | control plane **and** workloads (untainted after bootstrap) |
| `k8s-worker-0-bsides-krk-demo` | `10.1.1.41` | worker |

**Why two nodes:** the demo needs pod-to-pod traffic that crosses a node, or
every Hubble flow is node-local. Two schedulable nodes is the minimum.

## Files

| File | Contents |
|---|---|
| `provider.tf` | `bpg/proxmox` provider 0.99.0, endpoint from `pm_endpoint`, username/password auth, `insecure = true` (self-signed cert) |
| `backend.tf` | state in MinIO (S3), bucket `bifrost-minio-bucket`, key **`bsides-krk-lab/vms/terraform.tfstate`** |
| `main.tf` | the `master` VM and `worker` VMs (one per entry in `worker_ips`) |
| `variables.tf` | every input, with defaults |
| `outputs.tf` | IPs and an inventory preview |
| `terraform.tfvars.example` | copy to `terraform.tfvars` for laptop runs (gitignored) |

**The state key is the safety line.** It's `bsides-krk-lab/`, never
`bifrost-prod/`. If a plan ever shows a `bifrost-prod` name or proposes a destroy
you didn't expect, stop: the wrong state was loaded.

## What each VM gets

| Setting | Value | Why |
|---|---|---|
| Clone | full clone of `template_vm_id` | plain Ubuntu template (**not** the NVIDIA one) |
| CPU | 4 cores, type `host` | passes VT-x/AMD-V through for KubeVirt nested virt |
| Memory | 8 GiB | prod's 6 GiB control planes OOM'd; workers here also carry Tetragon, Hubble and a VM |
| Disk | 80 GB on `local-lvm`, raw, discard on | local disk on purpose: prod VM freezes hit guests on the Synology LUN |
| Network | `vnet1` (prod's SDN vnet), virtio, MTU inherited | |
| cloud-init | static IP, gateway `10.1.1.1`, DNS `192.0.2.168`, SSH keys for `ubuntu` | |
| Guest agent | disabled | |
| Tags | `bsides`, `lab`, `ebpf`, `disposable` | easy to spot in the Proxmox UI |

## Variables

| Variable | Default | Notes |
|---|---|---|
| `pm_endpoint` | `https://192.168.0.140:8006/` | sleipnir's Proxmox API |
| `pm_user` / `pm_password` | – (required, sensitive) | e.g. `root@pam`; never put in tfvars |
| `template_vm_id` | – (required) | currently **189** (`ubuntu-26.04-live-server-…-packer-build`) |
| `ssh_public_key` | – (required) | the **CI key** (`gitlab-ci bootstrap`); its private half is the `SSH_PRIVATE_KEY` CI variable |
| `extra_ssh_public_keys` | `""` | more keys, **one per line** (e.g. your personal login). A string, not a list, so an unset env var is simply empty |
| `proxmox_node` | `sleipnir` | changing it **replaces** the VMs |
| `network_bridge` | `vnet1` | |
| `datastore_id` | `local-lvm` | |
| `dns_server` | `192.0.2.168` | |
| `gateway_ip` | `10.1.1.1` | |
| `master_ip` | `10.1.1.40` | |
| `worker_ips` | `["10.1.1.41"]` | add an IP to add a worker (then update the inventory and run `make scale`) |

## Running it

**CI** (`.gitlab-ci.yml`): `plan-vms` → `apply-vms`, and `destroy` at the end.
Each job needs these project CI/CD variables:

| CI variable | Type | Used for |
|---|---|---|
| `MINIO_ACCESS_TOKEN`, `MINIO_SECRET_KEY` | Variable | state backend |
| `TF_VAR_PM_USER`, `TF_VAR_PM_PASSWORD` | Variable | Proxmox login |
| `TF_VAR_TEMPLATE_VM_ID` | Variable | `189`, digits only (the job checks this) |
| `TF_VAR_SSH_PUBLIC_KEY` | Variable | CI public key, one line |
| `TF_VAR_extra_ssh_public_keys` | Variable (optional) | extra public keys, one per line |

If the Proxmox password contains `$`, untick **Expand variable reference** on it.

**Laptop:** `make plan`, `make vms`, `make destroy-vms`, with
`TF_VAR_pm_user`, `TF_VAR_pm_password`, `MINIO_ACCESS_TOKEN`, `MINIO_SECRET_KEY`
exported and `terraform.tfvars` filled in.

Expected first plan: `Plan: 2 to add, 0 to change, 0 to destroy.`

## Known issues

- **Every clone has an extra blank 80 GB disk.** Template 189's disk is on
  `virtio0`, but `main.tf` declares the disk as `interface = "scsi0"`, so
  Proxmox keeps the cloned OS disk on `virtio0` **and** adds an empty disk on
  `scsi0`. The VM boots fine from `virtio0`, but 80 GB per VM is wasted on
  local-lvm, and the size/discard settings apply to the blank disk rather than
  the boot disk. Fix: `interface = "virtio0"` (prod has the same issue).
- **Plan doesn't test Proxmox credentials.** With nothing in state yet, the
  provider only logs in at apply time, so a bad password surfaces in `apply-vms`
  (`401 authentication failure`), not in `plan-vms`.
- Proxmox slows every failed login by about 3 s, so repeated bad-credential
  applies look like timeouts (`context deadline exceeded`).
