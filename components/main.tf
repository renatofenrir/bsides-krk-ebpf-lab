# ===========================================================================
# Lab add-on stack
#
# Same pattern as the prod bootstrapper's components/: every add-on is a module
# sourced from bifrost-k8s-extensions-module. Same modules, same interfaces --
# only the selection and the values differ, because a two-node disposable demo
# cluster wants a very different set from a 13-node production cluster.
#
# WHAT PROD INSTALLS AND THIS DELIBERATELY DOES NOT, and why:
#
#   metallb              Conflicts head-on with Cilium l2announcements, which
#                        Phase 1 enables. Both ARP for the same addresses.
#                        LoadBalancer IPs here come from the
#                        CiliumLoadBalancerIPPool instead.
#   ingress-nginx        The lab's ingress story IS Gateway API. Adding a
#                        second controller muddies the demo, and upstream
#                        archived ingress-nginx in March 2026 anyway.
#   cilium-post-install  Only fronts Hubble UI with an nginx Ingress. No
#                        ingress-nginx here, so it cannot apply. Reach Hubble
#                        with `cilium hubble ui`.
#   argocd               Nothing here is GitOps-reconciled. The lab is applied
#                        once and destroyed.
#   synology-csi         The lab's disks are local-lvm on purpose -- every VM
#                        freeze in prod hit a guest whose root disk was on the
#                        Synology LUN.
#   gpu-operator,        No GPUs in this cluster.
#   nvidia-gpu-exporter
#   harbor-pull-secret   All lab images are public (netshoot, nginx, the
#                        KubeVirt containerdisk). No registry auth needed.
#   loki, velero,        Nothing to back up and nobody to alert. A lab whose
#   exporters, alerting  whole lifespan is one conference session.
#   descheduler          Two nodes. Nothing to rebalance.
#   cert-manager,        Gateway API here is plain HTTP on an L2-announced IP.
#   traefik              No certificates, no second gateway implementation.
# ===========================================================================

# --- Module pin -----------------------------------------------------------
#
# Every source below is pinned to ONE commit of bifrost-k8s-extensions-module,
# not to main like prod.
#
# Prod tracks main because it is continuously reconciled and a drifting module
# gets noticed within a day. This lab is applied twice a year, minutes before a
# talk, where a module that moved underneath it fails at exactly the wrong
# moment.
#
# Terraform requires module.source to be a literal -- no variables, no locals,
# no interpolation -- so the ref is repeated on every module. To bump them all
# together, and then REHEARSE:
#
#   sed -i 's/?ref=[0-9a-f]\{40\}/?ref=<new-sha>/g' components/main.tf
#
# Pinned: bc4a1f4 ("fix(gpu-operator): tolerate the inference taint")

# --- Gateway API CRDs ------------------------------------------------------
#
# REQUIRED, and required EARLY. Cilium is installed with gatewayAPI.enabled=true,
# and the operator watches Gateway/HTTPRoute resources whose CRDs must already
# exist -- install Cilium first and it CrashLoopBackOffs on a missing-CRD error
# that reads like a Cilium bug and is not one.
#
# The module vendors the v1.5.1 standard channel rather than fetching from
# GitHub at apply time, so a venue network that cannot reach raw.githubusercontent
# does not stop the lab. That is also why this replaced the hand-rolled
# `kubectl apply -f <github url>` the install script used to do.
module "gateway_api_crds" {
  source = "git::https://gitlab.example.com/playground/bifrost-k8s-extensions-module.git//gateway-api-crds?ref=bc4a1f45947b6415a28d07e11376551d3a2daae6"
}

# --- metrics-server --------------------------------------------------------
# `kubectl top` during the KubeVirt section, to show what a VM actually costs.
module "metrics_server" {
  source = "git::https://gitlab.example.com/playground/bifrost-k8s-extensions-module.git//metrics-server?ref=bc4a1f45947b6415a28d07e11376551d3a2daae6"
}

# --- local-path storage ----------------------------------------------------
#
# The default StorageClass. Phase 3's VM boots from a containerDisk and needs
# no PVC, but KubeVirt's own components expect a default class to exist, and
# anything added to the lab later (a DataVolume, a real disk image) would too.
#
# Prod pins this module to GPU nodes via nvidia.com/gpu.present. There are no
# GPUs here, so the selector is widened to every Linux node -- the module
# requires a node_label_key, and kubernetes.io/os is the one label guaranteed
# to be on all of them.
module "local_path" {
  source = "git::https://gitlab.example.com/playground/bifrost-k8s-extensions-module.git//local-path?ref=bc4a1f45947b6415a28d07e11376551d3a2daae6"

  storage_class_name = var.storage_class_name
  default_path       = var.local_path_dir
  is_default         = true
  node_label_key     = "kubernetes.io/os"
  node_label_values  = ["linux"]

  depends_on = [module.metrics_server]
}

# --- CoreDNS ---------------------------------------------------------------
# Forwards the example.com zone at the internal resolver, so anything on the lab
# cluster resolves homelab names the same way prod workloads do.
module "coredns_config" {
  source = "git::https://gitlab.example.com/playground/bifrost-k8s-extensions-module.git//coredns-config?ref=bc4a1f45947b6415a28d07e11376551d3a2daae6"

  upstream_dns    = var.upstream_dns
  internal_domain = var.internal_domain

  depends_on = [module.metrics_server]
}

# --- Monitoring (optional, off by default) ---------------------------------
# See the note on var.enable_monitoring before switching this on.
module "kube_prometheus_stack" {
  source = "git::https://gitlab.example.com/playground/bifrost-k8s-extensions-module.git//kube-prometheus-stack?ref=bc4a1f45947b6415a28d07e11376551d3a2daae6"
  count  = var.enable_monitoring ? 1 : 0

  grafana_hostname            = "grafana.bsides-krk-demo.example.com"
  grafana_password            = var.grafana_password
  grafana_persistence_enabled = false

  # Small and short-lived: a talk is an hour, not a quarter.
  prometheus_retention       = "1d"
  prometheus_retention_size  = "2GiB"
  prometheus_storage_enabled = true
  prometheus_storage_size    = "5Gi"
  storage_class_name         = var.storage_class_name

  # Nobody to page during a conference talk.
  alertmanager_enabled            = false
  alertmanager_telegram_bot_token = null
  alertmanager_telegram_chat_id   = 0

  depends_on = [module.local_path]
}
