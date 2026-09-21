#!/usr/bin/env bash
# ===========================================================================
# PHASE 3 -- EXTENDED / NEW SECTION. NOT YET VALIDATED.
#
# Nothing below this line was run at the Heineken Kraków warm-up talk. Treat
# every step as a draft to be rehearsed, not as a known-good runbook.
# ===========================================================================
set -euo pipefail

KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-$(curl -sL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
echo "[INFO] KubeVirt ${KUBEVIRT_VERSION}"

kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

# --- Nested virtualisation check -------------------------------------------
# The lab VMs are cpu type=host, so they inherit VT-x/AMD-V *if* the Proxmox
# host has nesting on. If it does not, virt-launcher pods sit in Pending with
# no schedulable node and the error does not say "nested virt" anywhere.
echo
echo "[INFO] Checking for hardware virtualisation inside the guests..."
# Checked with kubectl, not ssh: /proc/cpuinfo is not namespaced, so a throwaway
# pod on the worker reports the node's CPU flags. The old ssh check failed with
# a misleading "no vmx/svm" whenever the laptop could not reach 10.1.1.41
# directly -- which is the normal case when kubectl goes through a TCP proxy.
NESTED=$(kubectl run nested-virt-check-$$ --image=busybox:1.36 --restart=Never --rm -i --quiet \
  --overrides='{"spec":{"nodeName":"k8s-worker-0-bsides-krk-demo"}}' \
  --command -- sh -c 'grep -cE "vmx|svm" /proc/cpuinfo' 2>/dev/null | tr -dc '0-9')
if [ "${NESTED:-0}" -gt 0 ]; then
  echo "[INFO] Hardware virtualisation available (${NESTED} CPUs report vmx/svm)."
else
  cat <<'WARN'
[WARN] No vmx/svm inside the guest. Enable nesting on the Proxmox host:
         echo "options kvm-intel nested=Y" | sudo tee /etc/modprobe.d/kvm-intel.conf
         # then reboot the host, or reload the module with no guests running
       ...or fall back to software emulation, which is SLOW but demos fine:
WARN
  echo "       kubectl -n kubevirt patch kubevirt kubevirt --type=merge \\"
  echo "         -p '{\"spec\":{\"configuration\":{\"developerConfiguration\":{\"useEmulation\":true}}}}'"
fi

echo
echo "[INFO] Waiting for KubeVirt to converge (this takes several minutes)..."
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=15m

# SKIP_VIRTCTL=1 skips the local install. It needs sudo, which has no terminal
# in an unattended run (`make kubevirt` from a script) and aborts the whole
# thing AFTER KubeVirt is installed but BEFORE the VM is applied. virtctl is
# already on the control plane via install-master-deps.yml, and nothing in the
# talk needs it on the laptop except `virtctl console`.
if [ "${SKIP_VIRTCTL:-0}" = "1" ]; then
  echo "[INFO] SKIP_VIRTCTL=1, not touching the local virtctl."
elif ! command -v virtctl >/dev/null; then
  echo "[INFO] Installing virtctl..."
  curl -sL --fail -o /tmp/virtctl \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  sudo install -m 0755 /tmp/virtctl /usr/local/bin/virtctl || {
    echo "[WARN] virtctl install failed (needs sudo). Continuing -- it is on the master already."; }
fi

command -v virtctl >/dev/null && virtctl version --client
kubectl -n kubevirt get kv kubevirt
