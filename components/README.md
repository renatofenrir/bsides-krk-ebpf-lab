# components/ — Terraform: in-cluster add-ons

Everything installed *into* the running cluster with Terraform (Helm releases
and raw manifests), after Kubespray and Cilium. The same pattern and modules as
prod's `components/`, trimmed down for a two-node disposable lab.

```
components/
├── main.tf           which modules are used, and why others aren't
├── variables.tf      inputs
├── outputs.tf        statuses
├── provider.tf       helm / kubernetes / kubectl providers (same versions as prod)
├── backend.tf        MinIO state, key bsides-krk-lab/components/terraform.tfstate
└── modules/          vendored module copies → modules/README.md
```

## What gets installed

| Module | Installs | Why the lab wants it |
|---|---|---|
| `gateway_api_crds` | Gateway API **v1.5.1** CRDs (same as prod) | kept identical to prod; Cilium currently has Gateway API **off** |
| `metrics_server` | metrics-server Helm chart | `kubectl top`, e.g. to show what a KubeVirt VM costs |
| `local_path` | local-path-provisioner, StorageClass `local-path` | meant to be the default class, but **isn't** yet; see [`modules/local-path/README.md`](modules/local-path/README.md#watch-out) |
| `coredns_config` | CoreDNS + NodeLocalDNS ConfigMaps | resolves `example.com` through `192.0.2.168`, like prod |
| `kube_prometheus_stack` | Prometheus/Grafana | **off** (`enable_monitoring = false`) |

`metrics_server` goes first; `local_path` and `coredns_config` depend on it;
monitoring (if enabled) depends on `local_path`.

**Deliberately not installed** (full reasons in `main.tf`): MetalLB (clashes with
Cilium L2 announcements), ingress-nginx, cilium-post-install, ArgoCD,
synology-csi, GPU operator/exporter, Harbor pull secret, Loki, Velero,
exporters, alerting, descheduler, cert-manager, Traefik.

## Order relative to Cilium

1. **`bootstrap-crds`** (CI) / `make crds`: `terraform apply -target=module.gateway_api_crds`.
   Only the CRDs, before Cilium.
2. **`install-cilium`**: the cluster gets networking.
3. **`plan-components` → `apply-components`** (CI) / `make components`: everything else.

The rest can't go before Cilium: metrics-server and local-path would sit
`Pending` and Helm would time out after 5 minutes (`context deadline exceeded`).
If you ever see that, check `cilium status` before retrying.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `kube_context` | `bsides-krk-demo` | deliberately not a prod context name; `fetch-kubeconfig` renames the context to this |
| `kube_config_path` | `~/.kube/config` | CI mounts `$HOME/.kube`; the Makefile passes `/tmp/.kube/bsides-lab.conf` |
| `storage_class_name` | `local-path` | |
| `local_path_dir` | `/opt/local-path-provisioner` | on-node directory for volumes |
| `upstream_dns` | `192.0.2.168` | |
| `internal_domain` | `example.com` | |
| `enable_monitoring` | `false` | heaviest thing in the repo; nothing in the talk reads from it |
| `grafana_password` | `admin` | only used if monitoring is on |

## Things that look odd but are fine

- **CoreDNS ConfigMaps show as "will be created"** even though Kubespray
  already made them. The module uses server-side apply with
  `force_conflicts = true` and simply takes ownership. That's also what prod does.
- **A failed Helm release stays in state.** After a timeout the next apply
  retries it in place. Fix the cause first (usually networking) or it times out again.

## Re-syncing the vendored modules

These are copies from `bifrost-k8s-extensions-module` at commit `bc4a1f4`
(2026-09-12). They don't update themselves; see [`modules/README.md`](modules/README.md).
