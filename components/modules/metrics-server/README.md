# metrics-server

Installs **metrics-server** (Helm chart from
`kubernetes-sigs.github.io/metrics-server`) into namespace `metrics-server`, so
`kubectl top nodes|pods` and HPA work.

| | |
|---|---|
| Release | `metrics-server`, `create_namespace`, `wait = true`, `timeout = 300` |
| Args | `--kubelet-insecure-tls` (kubelet certs aren't signed for the node IPs) and `--kubelet-preferred-address-types=InternalIP` (scrape kubelets by IP, not hostname) |
| `metrics.enabled` | `true`: exposes metrics-server's own metrics |

**Inputs:** `chart_version` (default `null` = latest chart at apply time).
**Output:** `status`.

## Lab-specific notes

- The first add-on applied by `apply-components`; `local_path` and
  `coredns_config` wait for it.
- `wait = true` means it fails if the pod isn't Ready within **5 minutes**. On a
  fresh lab, that almost always means Cilium isn't healthy yet (no pod
  networking). Check `cilium status` before retrying.
- `chart_version = null` means the chart version isn't pinned. Pin it if you
  want rehearsal and talk to be identical.
