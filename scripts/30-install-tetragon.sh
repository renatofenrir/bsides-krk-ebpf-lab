#!/usr/bin/env bash
# Phase 2, step 1: Tetragon + the tetra CLI.
#
# Tetragon is NOT part of bifrost-k8s-extensions-module -- it has never been in
# the add-on stack, so this is a fresh install, not a re-deploy.
set -euo pipefail

TETRAGON_VERSION="${TETRAGON_VERSION:-1.4.0}"

helm repo add cilium https://helm.cilium.io >/dev/null
helm repo update >/dev/null

helm upgrade --install tetragon cilium/tetragon \
  --version "${TETRAGON_VERSION}" \
  --namespace kube-system \
  --set tetragon.enableProcessCred=true \
  --set tetragon.enableProcessNs=true

kubectl -n kube-system rollout status ds/tetragon --timeout=180s

# tetra CLI on the operator laptop
if ! command -v tetra >/dev/null; then
  echo "[INFO] Installing tetra CLI..."
  GOOS=$(go env GOOS 2>/dev/null || echo linux)
  GOARCH=$(go env GOARCH 2>/dev/null || echo amd64)
  curl -sL --fail "https://github.com/cilium/tetragon/releases/latest/download/tetra-${GOOS}-${GOARCH}.tar.gz" \
    | tar -xz -C /tmp
  sudo install /tmp/tetra /usr/local/bin/tetra
fi

tetra version
echo
echo "Ready. Stream events with:"
echo "  kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact"
