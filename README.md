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
components/             Terraform: add-ons
components/modules/     vendored copies of the extension modules
inventory/              Kubespray inventory + group-vars
install-master-deps.yml puts helm/cilium/hubble/tetra/virtctl on the master
scripts/                the bits the Makefile shells out to
phase2-container-lab/   Tetragon policies + attacker workload
phase3-kubevirt-lab/    DRAFT — KubeVirt VM, Gateway, L4/L7 policies
```

Every folder has its own README explaining what's in it and why:

| Folder | README |
|---|---|
| Tetragon policies, in depth | [`phase2-container-lab/policies/`](phase2-container-lab/policies/README.md) |
| Phase 2 overview / attack pods | [`phase2-container-lab/`](phase2-container-lab/README.md), [`attack/`](phase2-container-lab/attack/README.md) |
| Phase 3 VM + L4/L7 network policies | [`phase3-kubevirt-lab/`](phase3-kubevirt-lab/README.md) |
| VMs, inventory, scripts | [`vms/`](vms/README.md), [`inventory/`](inventory/README.md), [`scripts/`](scripts/README.md) |
| Add-ons and each module | [`components/`](components/README.md), [`components/modules/`](components/modules/README.md) |

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

**Vendored** into `components/modules/`, copied out of
`bifrost-k8s-extensions-module` at commit `bc4a1f4`: **gateway-api-crds**,
**metrics-server**, **local-path**, **coredns-config**, plus
**kube-prometheus-stack** wired up but off (set `enable_monitoring = true` to turn it on).

Vendored rather than referenced so this repo depends on no other repo. A
`terraform init` here needs no GitLab reachability and no `CI_JOB_TOKEN`, and
prod moving its module repo forward between rehearsal and talk cannot change
what the lab installs. The trade is that upstream fixes do not arrive on their
own — `components/main.tf` documents the re-sync.

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

## Dependencies

The only things this repo reaches for are the Proxmox API, your MinIO state
backend, the container images (`quay.io/kubespray`, `renatofenrir/terraform`),
and `registry.terraform.io` for Terraform providers on first init. Both
`.terraform.lock.hcl` files are committed — init once before you travel and the
plugin cache serves them after that.

No other repo of yours is required, at build time or run time.

## Credentials

Nothing sensitive is committed. Export before running:

```bash
export TF_VAR_pm_user='root@pam' TF_VAR_pm_password='...'
export MINIO_ACCESS_TOKEN='...' MINIO_SECRET_KEY='...'   # Terraform backend
cp vms/terraform.tfvars.example vms/terraform.tfvars      # then edit
```
