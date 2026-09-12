terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [kubernetes_namespace.monitoring]

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      prometheusOperator = {
        enabled = true
        admissionWebhooks = {
          enabled = false
          patch = {
            enabled = false
          }
        }
        tls = {
          enabled = false
        }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }

      prometheus = {
        prometheusSpec = {
          retention = var.prometheus_retention
          # Time-based retention alone doesn't self-limit -- if daily data
          # volume grows (more scrape targets added over time), "N days"
          # silently needs more disk than whatever the PVC was sized for,
          # with no warning until it's already filling up. retentionSize
          # caps by actual bytes used: Prometheus deletes the oldest blocks
          # once storage approaches this regardless of the time window, so
          # growth degrades retention window gracefully instead of filling
          # the disk outright. Leave real headroom below the PVC size --
          # compaction needs scratch space to write new blocks before
          # deleting old ones.
          retentionSize = var.prometheus_retention_size
          storageSpec = var.prometheus_storage_enabled ? {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.storage_class_name
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = var.prometheus_storage_size
                  }
                }
              }
            }
          } : {}
          # cpu limit was 500m against a 100m request — a 5x burst ratio that
          # CFS-throttled Prometheus badly enough to cause missed/failed rule
          # evaluations (PrometheusMissingRuleEvaluations/RuleFailures firing
          # in lockstep with CPUThrottlingHigh). Raised headroom on both ends.
          #
          # 2026-07-27: memory limit (1Gi) turned out to be the next
          # bottleneck once Loki/Alloy/Velero and several exporters added
          # more scrape targets, series, and rule-eval load -- Prometheus was
          # getting OOMKilled (exit 137) roughly every 15-20 minutes during
          # normal operation (TSDB compaction was in-flight in the last log
          # line before each kill), not failing at startup. Raised memory
          # headroom accordingly; bumped CPU further too since slow
          # rule-eval under load can independently trip the liveness probe.
          resources = {
            requests = {
              cpu    = "250m"
              memory = "768Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }
        }
      }

      alertmanager = merge(
        {
          enabled = var.alertmanager_enabled
          alertmanagerSpec = {
            resources = {
              requests = {
                cpu    = "25m"
                memory = "64Mi"
              }
              limits = {
                cpu    = "100m"
                memory = "128Mi"
              }
            }
          }
        },
        var.alertmanager_telegram_bot_token != null ? {
          # Keeps the chart's default inhibit_rules and Watchdog->null route,
          # only swapping the default receiver from 'null' to telegram.
          config = {
            global = {
              resolve_timeout = "5m"
            }
            inhibit_rules = [
              {
                source_matchers = ["severity = critical"]
                target_matchers = ["severity =~ warning|info"]
                equal           = ["namespace", "alertname"]
              },
              {
                source_matchers = ["severity = warning"]
                target_matchers = ["severity = info"]
                equal           = ["namespace", "alertname"]
              },
              {
                source_matchers = ["alertname = InfoInhibitor"]
                target_matchers = ["severity = info"]
                equal           = ["namespace"]
              },
              {
                target_matchers = ["alertname = InfoInhibitor"]
              }
            ]
            route = {
              group_by        = ["namespace"]
              group_wait      = "30s"
              group_interval  = "5m"
              repeat_interval = "12h"
              receiver        = "telegram"
              routes = [
                {
                  receiver = "null"
                  matchers = ["alertname = \"Watchdog\""]
                },
                {
                  # InfoInhibitor is chart-default inhibition plumbing (fires
                  # whenever a lone info-level alert has nothing higher
                  # severity in-namespace to justify suppressing it) — not
                  # actionable on its own, so keep it out of Telegram.
                  receiver = "null"
                  matchers = ["alertname = \"InfoInhibitor\""]
                }
              ]
            }
            receivers = [
              { name = "null" },
              {
                name = "telegram"
                telegram_configs = [
                  {
                    send_resolved = true
                    api_url       = "https://api.telegram.org"
                    bot_token     = var.alertmanager_telegram_bot_token
                    chat_id       = var.alertmanager_telegram_chat_id
                    parse_mode    = "HTML"
                    # Alertmanager's built-in default template dumps every
                    # alert's full description + runbook_url; with
                    # group_by=["namespace"] that blows past Telegram's
                    # 4096-char limit once a namespace has more than a
                    # handful of alerts firing at once. This one keeps it to
                    # alertname/severity/summary, capped at 8 alerts.
                    #
                    # 2026-07-27: the summary annotation alone is static
                    # boilerplate text (e.g. "Processes experience elevated
                    # CPU throttling.") with zero indication of *which*
                    # pod/node/PVC it's about -- added the actual firing
                    # labels (whichever apply per alert) so a message is
                    # actionable without needing to go check Grafana first.
                    # Cap dropped from 15->8 to keep the same length safety
                    # margin now that each alert takes 3 lines instead of 2.
                    message = <<-EOT
                      {{ if gt (len .Alerts) 8 }}⚠️ <b>{{ len .Alerts }} alerts</b> in <b>{{ .CommonLabels.namespace }}</b> (showing first 8)
                      {{ end }}{{ range $i, $a := .Alerts }}{{ if lt $i 8 }}{{ if eq $a.Status "firing" }}🔥{{ else }}✅{{ end }} <b>{{ $a.Labels.alertname }}</b> [{{ $a.Labels.severity }}]
                      {{ if $a.Labels.namespace }}ns: {{ $a.Labels.namespace }} {{ end }}{{ if $a.Labels.pod }}pod: {{ $a.Labels.pod }} {{ end }}{{ if $a.Labels.container }}container: {{ $a.Labels.container }} {{ end }}{{ if $a.Labels.persistentvolumeclaim }}pvc: {{ $a.Labels.persistentvolumeclaim }} {{ end }}{{ if $a.Labels.node }}node: {{ $a.Labels.node }} {{ end }}{{ if $a.Labels.instance }}instance: {{ $a.Labels.instance }}{{ end }}
                      {{ if $a.Annotations.summary }}{{ $a.Annotations.summary }}
                      {{ end }}{{ end }}{{ end }}
                    EOT
                  }
                ]
              }
            ]
            templates = ["/etc/alertmanager/config/*.tmpl"]
          }
        } : {}
      )

      grafana = {
        enabled       = true
        adminPassword = var.grafana_password
        image = {
          tag = "12.3.9"
        }
        deploymentStrategy = {
          type = "Recreate"
        }
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts            = [var.grafana_hostname]
          annotations = {
            "nginx.ingress.kubernetes.io/ssl-redirect"       = "false"
            "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
            "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
          }
        }
        persistence = {
          enabled          = var.grafana_persistence_enabled
          storageClassName = var.storage_class_name
          size             = "5Gi"
        }
        resources = {
          requests = {
            cpu    = "300m"
            memory = "768Mi"
          }
          limits = {
            cpu    = "1500m"
            memory = "1536Mi"
          }
        }
        sidecar = {
          dashboards = {
            enabled = true
          }
          datasources = {
            enabled = true
          }
        }
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [
              {
                name            = "default"
                orgId           = 1
                folder          = "Bifrost"
                type            = "file"
                disableDeletion = false
                editable        = true
                options = {
                  path = "/var/lib/grafana/dashboards/default"
                }
              }
            ]
          }
        }
        dashboards = {
          default = {
            node-exporter-full = {
              gnetId     = 1860
              revision   = 37
              datasource = "Prometheus"
            }
            kubernetes-cluster = {
              gnetId     = 7249
              revision   = 1
              datasource = "Prometheus"
            }
            kubernetes-views-pods = {
              gnetId     = 15760
              revision   = 28
              datasource = "Prometheus"
            }
            nvidia-gpu-exporter = {
              gnetId     = 14574
              revision   = 8
              datasource = "Prometheus"
            }
            nvidia-dcgm = {
              gnetId     = 12239
              revision   = 2
              datasource = "Prometheus"
            }
            proxmox-ve = {
              json = file("${path.module}/dashboards/proxmox-ve.json")
            }
            synology-nas = {
              gnetId     = 14284
              revision   = 1
              datasource = "Prometheus"
            }
            energy-cost = {
              json = templatefile("${path.module}/dashboards/energy-cost.json.tftpl", {
                pln_per_kwh = var.electricity_price_pln_per_kwh
              })
            }
          }
        }
      }

      "prometheus-node-exporter" = {
        extraArgs = var.node_exporter_rapl_enabled ? ["--collector.rapl"] : []
        # 2026-07-27: 100m limit was fine when this was first sized, but
        # node-exporter runs with host network/PID namespaces -- every
        # scrape enumerates every interface and mount on the actual node,
        # not just its own container. Cluster density has grown a lot since
        # (Loki's Alloy DaemonSet on every node, one Cilium veth per pod
        # anywhere on that node), so the real per-scrape cost grew right
        # along with it while this limit stayed static. CPUThrottlingHigh
        # was firing on every single node-exporter pod, not random
        # workloads -- a config problem, not organic per-pod noise.
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "400m"
            memory = "128Mi"
          }
        }
      }

      "kube-state-metrics" = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }

      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeEtcd              = { enabled = false }
      kubeProxy             = { enabled = false }
      coreDns               = { enabled = true }

      # Custom rules on top of the chart's own defaults (see ALERTS.md).
      # These cover gaps the 2026-08-03 incident exposed: a Proxmox host
      # (sleipnir) went down with no alert, a GPU fell off the bus with no
      # alert, and an external reverse proxy (NPM) misroute broke every
      # ingress hostname with no alert -- none of that is caught by anything
      # the chart ships out of the box, since those failure points sit
      # outside what kube-state-metrics/node-exporter/etc. can see.
      additionalPrometheusRulesMap = {
        bifrost-custom-alerts = {
          groups = [
            {
              name = "bifrost.proxmox"
              rules = [
                {
                  alert = "ProxmoxNodeDown"
                  expr  = "pve_up{id=~\"node/.+\"} == 0"
                  for   = "2m"
                  labels = {
                    severity = "critical"
                  }
                  annotations = {
                    summary     = "Proxmox node {{ $labels.id }} is down"
                    description = "prometheus-pve-exporter has reported {{ $labels.id }} as down for over 2 minutes. This is the hypervisor host itself, not a single VM -- every guest running on it is affected."
                  }
                }
              ]
            },
            {
              name = "bifrost.gpu"
              rules = [
                {
                  alert = "NvidiaGPUExporterDown"
                  expr  = "up{job=\"nvidia-gpu-exporter\"} == 0"
                  for   = "5m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "nvidia-gpu-exporter target {{ $labels.instance }} is down"
                    description = "Prometheus hasn't been able to scrape nvidia-gpu-exporter on {{ $labels.instance }} for over 5 minutes. Often means the GPU driver/passthrough on that node is in a broken state (GSP RPC hang, GPU fell off the bus) rather than the exporter pod itself crashing -- worth checking nvidia-smi on that node directly."
                  }
                }
              ]
            },
            {
              name = "bifrost.external-endpoints"
              rules = [
                {
                  alert = "IngressEndpointDown"
                  expr  = "probe_success == 0"
                  for   = "3m"
                  labels = {
                    severity = "critical"
                  }
                  annotations = {
                    summary     = "External endpoint {{ $labels.instance }} is unreachable"
                    description = "blackbox-exporter has failed to get a successful HTTPS response from {{ $labels.instance }} for over 3 minutes. This probes the full external path (DNS -> reverse proxy -> ingress -> backend), so it catches outages anywhere in that chain, including outside the cluster."
                  }
                },
                {
                  alert = "IngressEndpointSlow"
                  expr  = "probe_duration_seconds{job=\"blackbox-exporter\"} > 5"
                  for   = "5m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "External endpoint {{ $labels.instance }} is slow to respond"
                    description = "{{ $labels.instance }} has taken more than 5s to respond to blackbox-exporter's probe for over 5 minutes."
                  }
                }
              ]
            }
          ]
        }
      }
    })
  ]

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
}