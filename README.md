# bsides-krk-ebpf-lab

Self-contained lab for the BSides Kraków talk on eBPF-based runtime security
with **Cilium** and **Tetragon**, plus a new **KubeVirt** section.

**Start here: [`LAB_GUIDE.md`](./LAB_GUIDE.md)** — the step-by-step runbook.

## Why this is its own repo

`k8s-playground-bootstrapper` on `main` targets the live `bifrost-prod-v4`
cluster: 3 masters, 5 workers, 4 GPU nodes, ArgoCD, Prometheus, Harbor, and a
shared MinIO state key at `bifrost-prod/`. Running a demo rebuild out of that
repo means a `destroy` stage and a production inventory one typo apart from
each other.

Nothing here is shared with it — separate state (local), separate inventory,
separate hostnames, separate IPs.

## Layout

```
terraform/              3 Proxmox VMs (1 control-plane + 2 workers)
ansible/                Kubespray inventory, CNI-less + kube-proxy-less
scripts/                00 → 40, run in order
phase2-container-lab/   ✅/⚠️  Tetragon policies + the attacker workload
phase3-kubevirt-lab/    🚧 DRAFT — KubeVirt VM, Gateway, L4/L7 policies
```

## Status of the material

- ✅ **Battle-tested** — presented at the Heineken Kraków warm-up talk: the
  Cilium flag set and the `kill-tcpdump` TracingPolicy.
- ⚠️ **Reconstructed** — original YAML lost with the deleted cluster; rebuilt
  from described behaviour: `monitor-network-activity-outside-cluster-cidr-range`
  and `kill-network-recon-binaries`.
- 🚧 **Draft** — everything under `phase3-kubevirt-lab/`. Never run. Rehearse
  before showing.

## Quick start

```bash
export TF_VAR_pm_user='root@pam' TF_VAR_pm_password='...'
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # then edit

./scripts/00-provision-vms.sh
./scripts/10-bootstrap-kubespray.sh
export KUBECONFIG=$PWD/ansible/artifacts/lab.kubeconfig
./scripts/20-install-cilium.sh
./scripts/25-cilium-lb-ipam.sh
./scripts/30-install-tetragon.sh
```

Then follow `LAB_GUIDE.md` from Phase 2.

## Cluster facts you will need

| | |
|---|---|
| Control plane | `10.1.1.40` |
| Workers | `10.1.1.41`, `10.1.1.42` |
| Pod CIDR | `10.233.64.0/18` |
| Service CIDR | `10.233.0.0/18` |
| LoadBalancer pool | `10.1.1.240–249` |

The pod/service CIDRs are hardcoded into the detection TracingPolicy. Change
one, change the other.
