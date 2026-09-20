#!/usr/bin/env bash
# Phase 2, step 1: Tetragon + the tetra CLI.
#
# Tetragon is NOT part of bifrost-k8s-extensions-module -- it has never been in
# the add-on stack, so this is a fresh install, not a re-deploy.
set -euo pipefail

TETRAGON_VERSION="${TETRAGON_VERSION:-1.4.0}"

helm repo add cilium https://helm.cilium.io >/dev/null
helm repo update >/dev/null

# --disable-kprobe-multi is NOT optional on this cluster. Verified 2026-09-20 on
# kernel 7.0.0-31-generic (Ubuntu 26.04): Tetragon 1.4.0's kprobe-multi object
# fails to load and EVERY TracingPolicy silently does nothing --
#   "failed prog /var/lib/tetragon/bpf_multi_kprobe_v61.o ...
#    program generic_kprobe_event: load program: invalid argument"
# The TracingPolicy CRD has no status field, so `kubectl get/describe
# tracingpolicy` looks perfectly healthy while nothing is hooked. The only
# evidence is `kubectl -n kube-system logs ds/tetragon -c tetragon | grep
# "adding tracing policy failed"`. Single kprobes work fine.
helm upgrade --install tetragon cilium/tetragon \
  --version "${TETRAGON_VERSION}" \
  --namespace kube-system \
  --set tetragon.enableProcessCred=true \
  --set tetragon.enableProcessNs=true \
  --set tetragon.extraArgs.disable-kprobe-multi=true

kubectl -n kube-system rollout status ds/tetragon --timeout=180s

# Fail loudly if a policy could not be loaded into the kernel -- this is the
# failure mode that looks like "the demo just does not work".
if kubectl -n kube-system logs ds/tetragon -c tetragon --tail=200 2>/dev/null \
     | grep -q "adding tracing policy failed"; then
  echo "[ERROR] Tetragon failed to load a TracingPolicy. Check:"
  echo "        kubectl -n kube-system logs ds/tetragon -c tetragon | grep 'adding tracing policy failed'"
  exit 1
fi

# tetra CLI on the operator laptop. SKIP_TETRA_CLI=1 skips it -- the talk drives
# tetra from inside the Tetragon pod anyway, and the install needs sudo, which
# would block an unattended rehearsal loop (`make lab-reset`).
if [ "${SKIP_TETRA_CLI:-0}" = "1" ]; then
  echo "[INFO] SKIP_TETRA_CLI=1, not touching the local tetra CLI."
elif ! command -v tetra >/dev/null; then
  echo "[INFO] Installing tetra CLI..."
  GOOS=$(go env GOOS 2>/dev/null || echo linux)
  GOARCH=$(go env GOARCH 2>/dev/null || echo amd64)
  curl -sL --fail "https://github.com/cilium/tetragon/releases/latest/download/tetra-${GOOS}-${GOARCH}.tar.gz" \
    | tar -xz -C /tmp
  sudo install /tmp/tetra /usr/local/bin/tetra
fi

command -v tetra >/dev/null && tetra version
echo
echo "Ready. Stream events with:  make events"
echo "  (per-node: the pod on the ATTACKER's node, not whatever ds/tetragon picks)"
