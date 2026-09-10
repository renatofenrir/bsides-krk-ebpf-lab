#!/usr/bin/env bash
# Phase 1, step 4: give Cilium a pool of LoadBalancer IPs and tell it to
# announce them on L2. This replaces MetalLB -- the two cannot coexist, both
# would ARP for the same addresses.
set -euo pipefail

kubectl apply -f - <<'YAML'
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: bsides-lab-pool
spec:
  blocks:
    # ACTION REQUIRED: confirm this range is free and OUTSIDE your DHCP scope.
    # Prod uses .50-.52, .60-.64, .90-.93; the lab nodes take .40-.42.
    - start: "10.1.1.240"
      stop: "10.1.1.249"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: bsides-lab-l2
spec:
  # Announce from the control plane only. Any node could do it, but pinning it
  # makes the demo deterministic: the ARP owner is always 10.1.1.40, so a
  # `arping` from the laptop gives the same answer every run. Drop the selector
  # to let all three nodes participate in leader election instead.
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
  interfaces:
    # ACTION REQUIRED: confirm the NIC name inside the guests.
    #   ssh ubuntu@10.1.1.40 ip -br addr
    # Ubuntu cloud images on virtio usually present ens18.
    - ^ens[0-9]+$
    - ^eth[0-9]+$
  externalIPs: true
  loadBalancerIPs: true
YAML

echo
echo "[INFO] Pools:"
kubectl get ciliumloadbalancerippools
kubectl get ciliuml2announcementpolicies
