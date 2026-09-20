# kube-prometheus-stack

Prometheus, Grafana, node-exporter, kube-state-metrics and (optionally)
Alertmanager, from the `prometheus-community` Helm chart pinned at **87.18.0**,
plus prod's custom dashboards and alert rules.

> **Off in the lab.** `components/main.tf` only creates it when
> `enable_monitoring = true` (default `false`). Nothing in the talk reads from
> it; the observability story is Hubble and tetra. This module is here unchanged
> from prod so it can be switched on if the talk ever gains a metrics segment.

## Files

| File | What it is |
|---|---|
| `main.tf` | namespace, the Helm release with all values, custom alert rules |
| `variables.tf` | inputs (defaults are prod's) |
| `outputs.tf` | `status`, `grafana_hostname` |
| `ALERTS.md` | reference for every alert rule and the Alertmanager/Telegram routing, **written for prod** |
| `dashboards/proxmox-ve.json` | Proxmox VE dashboard (needs a pve-exporter, which the lab doesn't have) |
| `dashboards/energy-cost.json.tftpl` | power draw / electricity cost dashboard (RAPL, `electricity_price_pln_per_kwh`) |

## What the lab passes when enabled

| Setting | Lab value | Prod-style default |
|---|---|---|
| `grafana_hostname` | `grafana.bsides-krk-demo.example.com` | `grafana.k8s-prod-v4.example.com` |
| `grafana_persistence_enabled` | `false` | `true` |
| `prometheus_retention` / `_size` | `1d` / `2GiB` | `7d` / unlimited |
| `prometheus_storage_size` | `5Gi` on `local-path` | `20Gi` on `synology-iscsi-storage` |
| `alertmanager_enabled` | `false` | `false` |
| Telegram token / chat | unset | prod secrets |

## If you turn it on, know that

- **Grafana's Ingress won't work.** It uses `ingressClassName: nginx`, and the
  lab has no ingress-nginx. Reach it with
  `kubectl -n kube-prometheus-stack port-forward svc/kube-prometheus-stack-grafana 3000:80`.
- **Several prod-only pieces have nothing to scrape:** the Proxmox dashboard and
  `ProxmoxNodeDown` alert (no pve-exporter), GPU exporter panels and alerts
  (no GPUs), `IngressEndpointDown` (no blackbox-exporter).
- **Memory:** Prometheus alone wants ~2 GiB; with two 8 GiB nodes also carrying
  Tetragon, Hubble and possibly a KubeVirt VM, it's tight.
- The RAPL collector (`node_exporter_rapl_enabled`) needs Intel RAPL / AMD
  energy support exposed inside the VM, which is often absent in guests.

`ALERTS.md` stays accurate for prod; for the lab, remember Alertmanager is off.
