# components/modules/ — vendored extension modules

Local copies of modules from the homelab repo `bifrost-k8s-extensions-module`,
taken at commit **`bc4a1f4`** on 2026-09-12. Prod fetches the same modules from
GitLab at `terraform init`; the lab keeps its own copies so it depends on no
other repo. A venue network that can't reach home, or prod's module repo moving
on, can't change what the lab installs.

| Module | Used by the lab | Summary |
|---|---|---|
| [`gateway-api-crds/`](gateway-api-crds/) | yes | Gateway API v1.5.1 CRDs from a vendored YAML file |
| [`metrics-server/`](metrics-server/) | yes | metrics-server Helm chart |
| [`local-path/`](local-path/) | yes | local-path-provisioner Helm chart |
| [`coredns-config/`](coredns-config/) | yes | CoreDNS and NodeLocalDNS Corefiles |
| [`kube-prometheus-stack/`](kube-prometheus-stack/) | **no** (off by default) | Prometheus, Grafana, alerting, prod dashboards |

## Re-syncing one from upstream

```bash
cp -r ../../bifrost-k8s-extensions-module/<name> components/modules/<name>
cd components && terraform init && terraform plan     # then rehearse
```

Local edits are allowed: these are the lab's copies now. If you make one, list
it in the "local edits" note in `components/main.tf` so a future re-sync doesn't
silently undo it. (Currently: none.)

## Providers are still online

Modules are local, but providers still download from `registry.terraform.io`
on the first `terraform init`. The lock files are committed; init once before
travelling and the plugin cache covers you.
