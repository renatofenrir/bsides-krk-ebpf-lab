# Alerting: Rules & Alertmanager Reference

Covers both halves of the alerting pipeline: every default Prometheus alert rule bundled by the `kube-prometheus-stack` Helm chart (pinned at `87.18.0` — see [`kube-prometheus-stack`](./README.md#kube-prometheus-stack)) as actually shipped for the components we have enabled, and how Alertmanager itself is configured to route those alerts to Telegram. Rule groups for disabled components (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy`) are intentionally omitted since they aren't deployed on this Kubespray cluster.

## How this pipeline works

```
Prometheus (evaluates rules below every 30s)
   -> firing alert
   -> Alertmanager (groups, dedupes, routes, silences)
   -> Telegram (via the alertmanager_telegram_bot_token/_chat_id wiring)
```

Prometheus owns *whether* something is wrong (the rules below). Alertmanager owns *what to do about it* — grouping related alerts into one notification, holding a `group_wait` before the first send, muting duplicates for `repeat_interval`, and deciding which receiver (Telegram, in our case) gets it. See `kube-prometheus-stack/main.tf`'s `alertmanager.config` block for the actual routing.

## Alertmanager configuration

Defined entirely in `kube-prometheus-stack/main.tf`, in the `alertmanager.config` block passed to the Helm chart. Nothing here is edited by hand in the cluster — change it in Terraform and re-apply.

### Routing tree
- Default receiver is `telegram`, but only when `alertmanager_telegram_bot_token` is set — otherwise the chart's own default applies and everything routes to a no-op `null` receiver (alerting silently off).
- `Watchdog` is explicitly routed to `null` — it's a meta-alert (see Severity levels below), never meant to reach Telegram.
- `group_by: ["namespace"]` — alerts sharing a namespace label get batched into one notification instead of one message per alert. Cluster-scoped alerts with no namespace label all land in the same shared bucket together.
- `group_wait: 30s` — how long a new alert group waits before its first notification, in case more alerts join it.
- `group_interval: 5m` — minimum gap between updates about an already-notified group.
- `repeat_interval: 12h` — how often a still-firing alert gets re-sent even if nothing changed.

### Receivers
- `null` — swallows whatever's routed to it (just `Watchdog`).
- `telegram` — one bot/chat via `telegram_configs`, using `alertmanager_telegram_bot_token`/`alertmanager_telegram_chat_id`.

### Inhibit rules
Carried over verbatim from the chart's own defaults (see `main.tf`): `critical` inhibits `warning`/`info` for the same alert+namespace, and `InfoInhibitor` suppresses `info`-only alerts once a real warning/critical is already firing for that alert. Keeps one incident from spamming multiple severity levels of the same problem.

### The compact Telegram message template
Alertmanager's *default* built-in template renders every alert's full `description` + `runbook_url`. Combined with `group_by: ["namespace"]` batching several alerts into one message, this exceeded Telegram's 4096-character limit the first time real alerts fired in bulk. The custom `message` field in `telegram_configs` (see `main.tf`) replaces it with alertname + severity + summary only, capped at the first 15 alerts per notification.

### Known gotchas (already hit these once — save yourself the rediscovery)
1. **`alertmanager_telegram_chat_id` must be a Terraform `number`, not `string`.** Alertmanager's schema requires int64 for `chat_id`. A string value renders it quoted, and prometheus-operator rejects the whole config secret (`cannot unmarshal !!str into int64`) — Alertmanager never starts, despite `terraform apply` reporting success. Symptom: `kubectl get alertmanager` shows `RECONCILED: False` and no pod exists at all.
2. **Message length.** See above — fixed via the compact template. If "message length exceeds telegram limits" shows up again, either a namespace has more alerts firing at once than the 15-alert cap accounts for, or someone reverted the custom `message` template.
3. **`amtool` needs `--alertmanager.url` explicitly**, even when run inside the Alertmanager pod itself — it doesn't default to talking to itself. Use `--alertmanager.url=http://localhost:9093`.
4. **Quote annotation values with spaces** in `amtool alert add` (e.g. `--annotation=summary="wiring test"`), or the newer UTF-8 matcher parser warns and falls back to the classic one.

### Verifying the live config directly
`terraform apply` reporting success only means `helm upgrade` succeeded — it does **not** confirm prometheus-operator actually reconciled the config into a running Alertmanager (see gotcha #1). To check what's really running:
```
kubectl -n kube-prometheus-stack get alertmanager
# READY / RECONCILED / AVAILABLE should all be truthy

kubectl -n kube-prometheus-stack get pods -l app.kubernetes.io/name=alertmanager

kubectl -n kube-prometheus-stack exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  cat /etc/alertmanager/config_out/alertmanager.env.yaml
```
That last file (`.env.yaml`, not `.yaml`) is the actual processed config prometheus-operator generated — ground truth, not the Helm values or the Terraform plan.

### Firing a test alert manually
```
kubectl -n kube-prometheus-stack exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert add alertname="test-alert" severity="warning" --annotation=summary="wiring test" \
  --alertmanager.url=http://localhost:9093
```
Expect it in Telegram roughly `group_wait` (30s) later. This alert goes straight into Alertmanager — Prometheus never sees it, so it won't appear on Prometheus's own `/alerts` page, only in Alertmanager itself (`amtool alert query --alertmanager.url=http://localhost:9093`, or Grafana's Alertmanager view).

---

## Severity levels

| Severity | Meaning |
|---|---|
| `critical` | Actively broken or about to be — worth interrupting for. |
| `warning` | Degraded or trending toward a problem — worth a look, not urgent. |
| `info` | Informational, no action implied on its own. |
| `none` | Meta-alerts (`Watchdog`, `InfoInhibitor`) that aren't real problems — see below. |

**Two special ones you'll see constantly and can ignore:**
- **`Watchdog`** — always firing by design, proves the Prometheus -> Alertmanager pipeline is alive. Routed to the `null` receiver in our config (see `main.tf`), so it never reaches Telegram.
- **`InfoInhibitor`** — suppresses `info`-severity alerts while a related `warning`/`critical` is already firing on the same alert, so you don't get both. Not a real problem either.

## Where to find these in Grafana

1. Left nav -> **Alerting** (bell icon) -> **Alertmanager**.
2. At the top of that page there's a data source picker, defaulting to `Grafana` (Grafana's own built-in alerting, which we don't use). Switch it to **`Alertmanager`** — this chart auto-provisions that data source (`grafana.sidecar.datasources.alertmanager.enabled: true` is the chart default, nothing we had to configure), pointed at the real in-cluster Alertmanager.
3. That view is the live, ground-truth list of what Alertmanager itself considers firing/silenced right now — the exact same state driving your Telegram messages. You can also create/manage silences from here.
4. To see a rule's *current value* against its threshold (not just whether it already fired), the more reliable route is Prometheus's own UI directly — `kubectl -n kube-prometheus-stack port-forward svc/prometheus-operated 9090:9090`, then `/alerts` on `localhost:9090`. Grafana's own "Alert rules" page is for Grafana-managed alerts, a separate system we're not using here — it won't show these by default.

---

## Custom (Bifrost) alert rules

Added on top of the chart's own defaults, via `additionalPrometheusRulesMap` in `main.tf` (rule group `bifrost-custom-alerts`). Unlike everything below, these aren't chart defaults — they exist because the 2026-08-03 incident exposed three failure points nothing shipped by the chart can see: a Proxmox host going down, a GPU falling off the bus, and an external reverse proxy (NPM, outside the cluster entirely) misrouting every ingress hostname. None of kube-state-metrics/node-exporter/etc. has visibility into any of those.

| Alert | Severity | What it means |
|---|---|---|
| `ProxmoxNodeDown` | critical | `pve_up{id=~"node/.+"}` is 0 for 2m+ — the Proxmox hypervisor host itself is down, not a single VM. Every guest on it is affected. |
| `NvidiaGPUExporterDown` | warning | `up{job="nvidia-gpu-exporter"}` is 0 for 5m+ — Prometheus can't scrape that node's GPU exporter. Often means the GPU driver/passthrough is wedged (GSP RPC hang, GPU fell off the bus) rather than the exporter pod itself crashing. |
| `IngressEndpointDown` | critical | `probe_success == 0` for 3m+ from `blackbox-exporter` — an external hostname (see `probe_targets` on the `blackbox-exporter` module) failed a full external-path HTTPS check (DNS → reverse proxy → ingress → backend). Catches outages anywhere in that chain, including outside the cluster — this is what would have caught the NPM outage. |
| `IngressEndpointSlow` | warning | `probe_duration_seconds{job="blackbox-exporter"} > 5` for 5m+ — an external hostname is responding, just slowly. |

`IngressEndpointDown`/`IngressEndpointSlow` only cover whatever URLs are listed in the `blackbox-exporter` module's `probe_targets` variable — add a hostname there (and re-apply) to get it probed.

---

## Alertmanager itself

| Alert | Severity | What it means |
|---|---|---|
| `AlertmanagerFailedReload` | critical | Reloading an Alertmanager configuration has failed. |
| `AlertmanagerMembersInconsistent` | critical | A member of an Alertmanager cluster has not found all other cluster members. |
| `AlertmanagerFailedToSendAlerts` | warning | An Alertmanager instance failed to send notifications. |
| `AlertmanagerClusterFailedToSendAlerts` | critical, warning | All Alertmanager instances in a cluster failed to send notifications to a critical integration. |
| `AlertmanagerConfigInconsistent` | critical | Alertmanager instances within the same cluster have different configurations. |
| `AlertmanagerClusterDown` | critical | Half or more of the Alertmanager instances within the same cluster are down. |
| `AlertmanagerClusterCrashlooping` | critical | Half or more of the Alertmanager instances within the same cluster are crashlooping. |
| `AlertmanagerClusterFailedPeers` | warning | An Alertmanager instance has failed peers in the cluster. |

## Config reloader sidecars

| Alert | Severity | What it means |
|---|---|---|
| `ConfigReloaderSidecarErrors` | warning | config-reloader sidecar has not had a successful reload for 10m |

## General / meta

| Alert | Severity | What it means |
|---|---|---|
| `TargetDown` | warning | One or more targets are unreachable. |
| `Watchdog` | none | An alert that should always be firing to certify that Alertmanager is working properly. |
| `InfoInhibitor` | none | Info-level alert inhibition. |

## Kubernetes API server SLOs

| Alert | Severity | What it means |
|---|---|---|
| `KubeAPIErrorBudgetBurn` | critical, warning | The Kube API server is burning too much error budget. |

## kube-state-metrics

| Alert | Severity | What it means |
|---|---|---|
| `KubeStateMetricsListErrors` | critical | kube-state-metrics is experiencing errors in list operations. |
| `KubeStateMetricsWatchErrors` | critical | kube-state-metrics is experiencing errors in watch operations. |
| `KubeStateMetricsShardingMismatch` | critical | kube-state-metrics sharding is misconfigured. |
| `KubeStateMetricsShardsMissing` | critical | kube-state-metrics shards are missing. |

## Workloads (Pods/Deployments/StatefulSets/DaemonSets/Jobs/HPA/PDB)

| Alert | Severity | What it means |
|---|---|---|
| `KubePodCrashLooping` | warning | Pod is crash looping. |
| `KubePodNotReady` | warning | Pod has been in a non-ready state for more than 15 minutes. |
| `KubeDeploymentGenerationMismatch` | warning | Deployment generation mismatch due to possible roll-back |
| `KubeDeploymentReplicasMismatch` | warning | Deployment has not matched the expected number of replicas. |
| `KubeDeploymentRolloutStuck` | warning | Deployment rollout is not progressing. |
| `KubeStatefulSetReplicasMismatch` | warning | StatefulSet has not matched the expected number of replicas. |
| `KubeStatefulSetGenerationMismatch` | warning | StatefulSet generation mismatch due to possible roll-back |
| `KubeStatefulSetUpdateNotRolledOut` | warning | StatefulSet update has not been rolled out. |
| `KubeDaemonSetRolloutStuck` | warning | DaemonSet rollout is stuck. |
| `KubeContainerWaiting` | warning | Pod container waiting longer than 1 hour |
| `KubeDaemonSetNotScheduled` | warning | DaemonSet pods are not scheduled. |
| `KubeDaemonSetMisScheduled` | warning | DaemonSet pods are misscheduled. |
| `KubeJobNotCompleted` | warning | Job did not complete in time |
| `KubeJobFailed` | warning | Job failed to complete. |
| `KubeHpaReplicasMismatch` | warning | HPA has not matched desired number of replicas. |
| `KubeHpaMaxedOut` | warning | HPA is running at max replicas |
| `KubePdbNotEnoughHealthyPods` | warning | PDB does not have enough healthy pods. |

## Cluster resource commitment

| Alert | Severity | What it means |
|---|---|---|
| `KubeCPUOvercommit` | warning | Cluster has overcommitted CPU resource requests. |
| `KubeMemoryOvercommit` | warning | Cluster has overcommitted memory resource requests. |
| `KubeCPUQuotaOvercommit` | warning | Cluster has overcommitted CPU resource requests. |
| `KubeMemoryQuotaOvercommit` | warning | Cluster has overcommitted memory resource requests. |
| `KubeQuotaAlmostFull` | info | Namespace quota is going to be full. |
| `KubeQuotaFullyUsed` | info | Namespace quota is fully used. |
| `KubeQuotaExceeded` | warning | Namespace quota has exceeded the limits. |
| `CPUThrottlingHigh` | info | Processes experience elevated CPU throttling. |

## Storage (PersistentVolumes)

| Alert | Severity | What it means |
|---|---|---|
| `KubePersistentVolumeFillingUp` | critical, warning | PersistentVolume is filling up. |
| `KubePersistentVolumeInodesFillingUp` | critical, warning | PersistentVolumeInodes are filling up. |
| `KubePersistentVolumeErrors` | critical | PersistentVolume is having issues with provisioning. |

## Kubernetes API server

| Alert | Severity | What it means |
|---|---|---|
| `KubeClientCertificateExpiration` | warning, critical | Client certificate is about to expire. |
| `KubeAggregatedAPIErrors` | warning | Kubernetes aggregated API has reported errors. |
| `KubeAggregatedAPIDown` | warning | Kubernetes aggregated API is down. |
| `KubeAPIDown` | critical | Target disappeared from Prometheus target discovery. |
| `KubeAPIInstanceUnreachable` | warning | KubeAPI instance is unreachable. |
| `KubeAPITerminatedRequests` | warning | The kubernetes apiserver has terminated a significant percentage of its incoming requests. |

## Nodes & kubelet

| Alert | Severity | What it means |
|---|---|---|
| `KubeNodeNotReady` | warning | Node is not ready. |
| `KubeNodePressure` | info | Node has as active Condition. |
| `KubeNodeUnreachable` | warning | Node is unreachable. |
| `KubeletTooManyPods` | info | Kubelet is running at capacity. |
| `KubeNodeReadinessFlapping` | warning | Node readiness status is flapping. |
| `KubeNodeEviction` | info | Node is evicting pods. |
| `KubeletPlegDurationHigh` | warning | Kubelet Pod Lifecycle Event Generator is taking too long to relist. |
| `KubeletPodStartUpLatencyHigh` | warning | Kubelet Pod startup latency is too high. |
| `KubeletClientCertificateExpiration` | warning, critical | Kubelet client certificate is about to expire. |
| `KubeletServerCertificateExpiration` | warning, critical | Kubelet server certificate is about to expire. |
| `KubeletClientCertificateRenewalErrors` | warning | Kubelet has failed to renew its client certificate. |
| `KubeletServerCertificateRenewalErrors` | warning | Kubelet has failed to renew its server certificate. |
| `KubeletInstanceUnreachable` | warning | Kubelet instance is unreachable. |
| `KubeletDown` | critical | Target disappeared from Prometheus target discovery. |

## Kubernetes system / client

| Alert | Severity | What it means |
|---|---|---|
| `KubeVersionMismatch` | warning | Different semantic versions of Kubernetes components running. |
| `KubeClientErrors` | warning | Kubernetes API server client is experiencing errors. |

## Host / node-exporter

| Alert | Severity | What it means |
|---|---|---|
| `NodeFilesystemSpaceFillingUp` | warning, critical | Filesystem is predicted to run out of space within the next 24 hours. |
| `NodeFilesystemAlmostOutOfSpace` | warning, critical | Filesystem has less than 5% space left. |
| `NodeFilesystemFilesFillingUp` | warning, critical | Filesystem is predicted to run out of inodes within the next 24 hours. |
| `NodeFilesystemAlmostOutOfFiles` | warning, critical | Filesystem has less than 5% inodes left. |
| `NodeNetworkReceiveErrs` | warning | Network interface is reporting many receive errors. |
| `NodeNetworkTransmitErrs` | warning | Network interface is reporting many transmit errors. |
| `NodeHighNumberConntrackEntriesUsed` | warning | Number of conntrack are getting close to the limit. |
| `NodeTextFileCollectorScrapeError` | warning | Node Exporter text file collector failed to scrape. |
| `NodeClockSkewDetected` | warning | Clock skew detected. |
| `NodeClockNotSynchronising` | warning | Clock not synchronising. |
| `NodeRAIDDegraded` | critical | RAID Array is degraded. |
| `NodeRAIDDiskFailure` | warning | Failed device in RAID array. |
| `NodeFileDescriptorLimit` | warning, critical | Kernel is predicted to exhaust file descriptors limit soon. |
| `NodeCPUHighUsage` | info | High CPU usage. |
| `NodeSystemSaturation` | warning | System saturated, load per core is very high. |
| `NodeMemoryMajorPagesFaults` | warning | Memory major page faults are occurring at very high rate. |
| `NodeMemoryHighUtilization` | warning | Host is running out of memory. |
| `NodeDiskIOSaturation` | warning | Disk IO queue is high. |
| `NodeSystemdServiceFailed` | warning | Systemd service has entered failed state. |
| `NodeSystemdServiceCrashlooping` | warning | Systemd service keeps restaring, possibly crash looping. |
| `NodeBondingDegraded` | warning | Bonding interface is degraded. |

## Node networking

| Alert | Severity | What it means |
|---|---|---|
| `NodeNetworkInterfaceFlapping` | warning | Network interface is often changing its status |

## Prometheus Operator

| Alert | Severity | What it means |
|---|---|---|
| `PrometheusOperatorListErrors` | warning | Errors while performing list operations in controller. |
| `PrometheusOperatorWatchErrors` | warning | Errors while performing watch operations in controller. |
| `PrometheusOperatorSyncFailed` | warning | Last controller reconciliation failed |
| `PrometheusOperatorReconcileErrors` | warning | Errors while reconciling objects. |
| `PrometheusOperatorStatusUpdateErrors` | warning | Errors while updating objects status. |
| `PrometheusOperatorNodeLookupErrors` | warning | Errors while reconciling Prometheus. |
| `PrometheusOperatorNotReady` | warning | Prometheus operator not ready |
| `PrometheusOperatorRejectedResources` | warning | Resources rejected by Prometheus operator |

## Prometheus itself

| Alert | Severity | What it means |
|---|---|---|
| `PrometheusBadConfig` | critical | Failed Prometheus configuration reload. |
| `PrometheusSDRefreshFailure` | warning | Failed Prometheus SD refresh. |
| `PrometheusKubernetesListWatchFailures` | warning | Requests in Kubernetes SD are failing. |
| `PrometheusNotificationQueueRunningFull` | warning | Prometheus alert notification queue predicted to run full in less than 30m. |
| `PrometheusErrorSendingAlertsToSomeAlertmanagers` | warning | More than 1% of alerts sent by Prometheus to a specific Alertmanager were affected by errors. |
| `PrometheusNotConnectedToAlertmanagers` | warning | Prometheus is not connected to any Alertmanagers. |
| `PrometheusTSDBReloadsFailing` | warning | Prometheus has issues reloading blocks from disk. |
| `PrometheusTSDBCompactionsFailing` | warning | Prometheus has issues compacting blocks. |
| `PrometheusNotIngestingSamples` | warning | Prometheus is not ingesting samples. |
| `PrometheusDuplicateTimestamps` | warning | Prometheus is dropping samples with duplicate timestamps. |
| `PrometheusOutOfOrderTimestamps` | warning | Prometheus drops samples with out-of-order timestamps. |
| `PrometheusRemoteStorageFailures` | critical | Prometheus fails to send samples to remote storage. |
| `PrometheusRemoteWriteBehind` | critical | Prometheus remote write is behind. |
| `PrometheusRemoteWriteDesiredShards` | warning | Prometheus remote write desired shards calculation wants to run more than configured max shards. |
| `PrometheusRuleFailures` | critical | Prometheus is failing rule evaluations. |
| `PrometheusMissingRuleEvaluations` | warning | Prometheus is missing rule evaluations due to slow rule group evaluation. |
| `PrometheusTargetLimitHit` | warning | Prometheus has dropped targets because some scrape configs have exceeded the targets limit. |
| `PrometheusLabelLimitHit` | warning | Prometheus has dropped targets because some scrape configs have exceeded the labels limit. |
| `PrometheusScrapeBodySizeLimitHit` | warning | Prometheus has dropped some targets that exceeded body size limit. |
| `PrometheusScrapeSampleLimitHit` | warning | Prometheus has failed scrapes that have exceeded the configured sample limit. |
| `PrometheusTargetSyncFailure` | critical | Prometheus has failed to sync targets. |
| `PrometheusHighQueryLoad` | warning | Prometheus is reaching its maximum capacity serving concurrent requests. |
| `PrometheusErrorSendingAlertsToAnyAlertmanager` | critical | Prometheus encounters more than 3% errors sending alerts to any Alertmanager. |
