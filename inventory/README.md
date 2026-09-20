# inventory/ — Kubespray inventory and settings

What Kubespray needs to turn the two VMs from [`../vms/`](../vms/) into a
Kubernetes cluster.

```
inventory/
├── inventory.ini              which host plays which role
└── group-vars/all/all.yml     cluster settings (applies to every host)
```

Both are mounted **read-only** into the Kubespray container
(`quay.io/kubespray/kubespray:v2.31.0`) by the `bootstrap-cluster` CI job and
`make cluster`. `group-vars/` is mounted as the container's `group_vars/`.
The name differs on disk; that's intentional.

## `inventory.ini`

| Group | Hosts | Meaning |
|---|---|---|
| `kube_control_plane` | master (`10.1.1.40`) | API server, scheduler, controller manager |
| `etcd` | master | single etcd member |
| `kube_node` | master **and** worker (`10.1.1.41`) | runs pods |
| `k8s_cluster` | children: control plane + nodes | everything Kubespray manages |

The master is in `kube_node` too, so it runs kubelet as a normal node.
Kubespray still taints it `NoSchedule`; the separate untaint step (`make untaint`,
or the end of `bootstrap-cluster`) makes it actually schedulable.

Ansible connects as `ubuntu` with `become`. In CI the key is `SSH_PRIVATE_KEY`;
on a laptop it's `SSH_KEY` in the Makefile (default `~/.ssh/id_rsa`).

If you see a `bifrost-prod` hostname in this file, stop.

## `group-vars/all/all.yml`

| Setting | Value | Why |
|---|---|---|
| `kube_network_plugin` | `cni` | **no CNI from Kubespray.** Cilium is installed afterwards with `cilium install` (the talk's Phase 1 moment), and `ipam.mode` can't be changed after install, so it has to be Cilium's own install that sets it |
| `kube_network_plugin_multus` | `false` | no Multus |
| `kube_proxy_remove` | `true` | no kube-proxy; Cilium replaces it in eBPF |
| `kube_pods_subnet` | `10.233.64.0/18` | **hard-coded in the detection TracingPolicy** too |
| `kube_service_addresses` | `10.233.0.0/18` | same. CoreDNS ends up on `10.233.0.3`, which the coredns-config module also hard-codes |
| `kube_version` | `1.35.4` | same as prod. **No leading `v`**: Kubespray 2.31 crashes on it. Must be within 1.33.0–1.35.4 for this Kubespray |
| `upstream_dns_servers` | `192.0.2.168`, `8.8.8.8` | homelab resolver first |
| `kubeconfig_localhost` / `kubectl_localhost` | `true` | meant to copy the kubeconfig back. Because the inventory is mounted read-only inside a throwaway container, the copy never reaches your disk; the kubeconfig actually comes from `make kubeconfig` / the `fetch-kubeconfig` job |
| `supplementary_addresses_in_ssl_keys` | `10.1.1.40` | puts the node IP in the API server cert, so a kubeconfig pointing at `https://10.1.1.40:6443` validates. Before Cilium is up that's the only reachable API address |
| `etcd_deployment_type` | `host` | etcd as a systemd service; one member (no quorum, fine for a lab) |

## What to expect after Kubespray

- Both nodes **`NotReady`**, CoreDNS **`Pending`**. That's correct: there's no
  CNI yet. `install-cilium` makes them `Ready`.
- The master is tainted until the untaint step runs.

## Changing things

| If you change… | …also change |
|---|---|
| pod or service CIDR | `phase2-container-lab/policies/00-monitor-outside-cluster-cidr.yaml`; `coredns_ip` in `components/modules/coredns-config` |
| `kube_version` | keep it matching prod and inside Kubespray's supported range |
| add a node | `vms/variables.tf` `worker_ips`, this inventory, then `make scale` |
