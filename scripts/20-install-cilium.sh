#!/usr/bin/env bash
# Phase 1, step 3: Cilium, with the exact flag set from the original lab.
#
# BATTLE-TESTED: this flag set is the one presented at the Heineken Kraków
# warm-up talk, with two additions called out inline below.
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.18.1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"
API_SERVER_IP="${API_SERVER_IP:-10.1.1.40}"

# ---------------------------------------------------------------------------
# Gateway API CRDs FIRST.
#
# --set gatewayAPI.enabled=true makes the operator watch resources whose CRDs
# must already exist. Install Cilium first and the operator CrashLoopBackOffs
# on a missing-CRD error that reads like a Cilium bug and is not one.
# ---------------------------------------------------------------------------
echo "[INFO] Installing Gateway API ${GATEWAY_API_VERSION} CRDs..."
BASE="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl apply -f "$BASE"

# TLSRoute ships in the experimental channel only; Cilium's Gateway API
# support expects the CRD to be present even when unused.
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"

echo
echo "[INFO] Installing Cilium ${CILIUM_VERSION}..."
cilium install --version "${CILIUM_VERSION}" \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set l2announcements.enabled=true \
  --set gatewayAPI.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set socketLB.hostNamespaceOnly=true \
  --set k8sServiceHost="${API_SERVER_IP}" \
  --set k8sServicePort=6443 \
  --set k8sClientRateLimit.qps=50 \
  --set k8sClientRateLimit.burst=200

# --- On the two flags that are NOT from the original runbook ---------------
#
# k8sServiceHost / k8sServicePort
#   kube-proxy is gone, so nothing has programmed the 10.233.0.1 ClusterIP
#   yet -- but Cilium needs the API server to start, and it is Cilium that
#   would program it. Pointing at the real node IP breaks the cycle. The prod
#   repo carries the same workaround in cilium-extra-vars.yml.
#
# k8sClientRateLimit.qps / .burst
#   l2announcements drives leader election through Leases, which is a lot of
#   API writes. At the client-go defaults (5 qps) the agents get throttled and
#   LB IPs flap -- announced, withdrawn, re-announced -- which on stage looks
#   exactly like a broken demo.
#
# socketLB.hostNamespaceOnly=true is from the original runbook and is load
# bearing for Phase 3: without it socket-level LB rewrites connections inside
# the virt-launcher pod and KubeVirt VM networking breaks in confusing ways.

echo
echo "[INFO] cilium status --wait ..."
cilium status --wait

echo
echo "[INFO] Nodes should now be Ready:"
kubectl get nodes -o wide
