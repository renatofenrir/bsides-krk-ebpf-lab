# bsides-krk-ebpf-lab

Self-contained lab for the BSides Kraków talk on eBPF-based runtime security
with **Cilium** and **Tetragon**, plus a new **KubeVirt** section.

Build it, run the talk on it, destroy it:

```bash
make up      # two VMs → Kubernetes → Cilium → add-ons   (~35-45 min)
make lab     # Tetragon + the attacker workload
make down    # gone
```

**Start here: [`LAB_GUIDE.md`](./LAB_GUIDE.md)** — the step-by-step runbook.
`make help` lists every target.

## Why this is its own repo

`k8s-playground-bootstrapper` on `main` targets the live `bifrost-prod-v4`
cluster: 3 masters, 5 workers, 4 GPU nodes, ArgoCD, Prometheus, Harbor, and a
shared MinIO state key at `bifrost-prod/`. Running a demo rebuild out of that
repo means a `destroy` stage and a production inventory one typo apart.

This repo mirrors its structure — `vms/` and `components/` Terraform stacks,
`inventory/` for Kubespray, a staged all-manual `.gitlab-ci.yml`, Terraform in
`renatofenrir/terraform:v7`, MinIO as the state backend — but shares no state
key, inventory, hostname or IP with it. The lab's state prefix is
`bsides-krk-lab/`.

## Layout

```
Makefile                make up / make lab / make down
.gitlab-ci.yml          staged, every job manual, mirrors prod's shape
vms/                    Terraform: 2 Proxmox VMs
components/             Terraform: add-ons, from bifrost-k8s-extensions-module
inventory/              Kubespray inventory + group-vars
install-master-deps.yml puts helm/cilium/hubble/tetra/virtctl on the master
scripts/                the bits the Makefile shells out to
phase2-container-lab/   Tetragon policies + attacker workload
phase3-kubevirt-lab/    DRAFT — KubeVirt VM, Gateway, L4/L7 policies
```

## The cluster

Two nodes. The control plane is untainted and carries workloads, which is the
smallest cluster that still gives Hubble **cross-node** flows to draw — on a
single node every flow is local and the datapath story falls flat.

| | |
|---|---|
| `k8s-master-0-bsides-krk-demo` | `10.1.1.40` — control plane, schedulable |
| `k8s-worker-0-bsides-krk-demo` | `10.1.1.41` — worker |
| Pod CIDR | `10.233.64.0/18` |
| Service CIDR | `10.233.0.0/18` |
| LoadBalancer pool | `10.1.1.240–249` (Cilium L2, no MetalLB) |

The pod/service CIDRs are hardcoded into the detection TracingPolicy. Change
one, change the other.

## Add-ons

Same modules as prod, from `bifrost-k8s-extensions-module`, pinned to one
commit rather than tracking `main`: **gateway-api-crds**, **metrics-server**,
**local-path**, **coredns-config**. `kube-prometheus-stack` is wired up but off
(`enable_monitoring = true` to enable).

Deliberately absent, each for a reason documented in `components/main.tf`:
MetalLB (conflicts with Cilium `l2announcements`), ingress-nginx, ArgoCD,
synology-csi, gpu-operator, Harbor pull secrets, Loki, Velero, the exporters,
descheduler, cert-manager and Traefik.

## Status of the material

- ✅ **Battle-tested** — presented at the Heineken Kraków warm-up talk: the
  Cilium flag set and the `kill-tcpdump` TracingPolicy.
- ⚠️ **Reconstructed** — original YAML lost with the deleted cluster; rebuilt
  from described behaviour: `monitor-network-activity-outside-cluster-cidr-range`
  and `kill-network-recon-binaries`.
- 🚧 **Draft** — everything under `phase3-kubevirt-lab/`. Never run. Rehearse
  before showing.

## Credentials

Nothing sensitive is committed. Export before running:

```bash
export TF_VAR_pm_user='root@pam' TF_VAR_pm_password='...'
export MINIO_ACCESS_TOKEN='...' MINIO_SECRET_KEY='...'   # Terraform backend
cp vms/terraform.tfvars.example vms/terraform.tfvars      # then edit
```
