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
if ! ssh -o StrictHostKeyChecking=no ubuntu@10.1.1.41 "grep -qE 'vmx|svm' /proc/cpuinfo"; then
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

if ! command -v virtctl >/dev/null; then
  echo "[INFO] Installing virtctl..."
  curl -sL --fail -o /tmp/virtctl \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  sudo install -m 0755 /tmp/virtctl /usr/local/bin/virtctl
fi

virtctl version --client
kubectl -n kubevirt get kv kubevirt
