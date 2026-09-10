#!/usr/bin/env bash
# Phase 1, step 2: kubeadm cluster via Kubespray, with NO CNI and NO kube-proxy.
#
# Nodes come out NotReady. That is correct -- 20-install-cilium.sh fixes it.
set -euo pipefail
cd "$(dirname "$0")/../ansible"

KUBESPRAY_IMG="${KUBESPRAY_IMG:-quay.io/kubespray/kubespray:v2.31.0}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

echo "[INFO] Waiting for SSH on all three lab nodes..."
ansible -i inventory.ini all \
  -m wait_for_connection -a "timeout=300 sleep=5 delay=10" \
  -e "ansible_user=ubuntu ansible_become=yes"

echo "[INFO] Waiting for cloud-init to settle..."
ansible -i inventory.ini all \
  -m shell -a "cloud-init status --wait" \
  -e "ansible_user=ubuntu ansible_become=yes"

echo "[INFO] Running Kubespray cluster.yml (CNI-less)..."
docker run --rm \
  -v "$PWD/inventory.ini:/kubespray/inventory/inventory.ini" \
  -v "$PWD/group_vars:/kubespray/inventory/group_vars" \
  -v "$PWD/artifacts:/kubespray/inventory/artifacts" \
  --mount "type=bind,source=${SSH_KEY},dst=/root/.ssh/id_rsa" \
  "$KUBESPRAY_IMG" \
  ansible-playbook -i inventory/inventory.ini \
    -e ansible_user=ubuntu \
    -e ansible_become=yes \
    -e host_key_checking=false \
    -e kube_owner=root \
    --private-key /root/.ssh/id_rsa \
    cluster.yml

echo
echo "[INFO] Fetching kubeconfig..."
mkdir -p artifacts
# admin.conf is root-owned on the master, so read it through sudo rather than
# scp-ing it as ubuntu.
ssh -o StrictHostKeyChecking=no ubuntu@10.1.1.40 \
  "sudo cat /etc/kubernetes/admin.conf" > artifacts/lab.kubeconfig
chmod 600 artifacts/lab.kubeconfig

# Point the kubeconfig at the node IP rather than the in-cluster ClusterIP:
# with kube-proxy removed and Cilium not yet installed, 10.233.0.1 is
# unreachable. This is the same chicken-and-egg the prod repo solves with
# k8sServiceHost.
sed -i 's#server: https://127.0.0.1:6443#server: https://10.1.1.40:6443#' artifacts/lab.kubeconfig

echo
echo "Done. Now:  export KUBECONFIG=$PWD/artifacts/lab.kubeconfig"
echo "Nodes will read NotReady until Cilium is installed. Expected."
