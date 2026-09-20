# scripts/

Small shell scripts the `Makefile` (and one CI job) call. The number prefix
matches the build order: `25` belongs to Phase 1, `30` to Phase 2, `40` to Phase 3.
All of them use `kubectl`/`helm` against whatever context is active, so export
the lab kubeconfig first (`export KUBECONFIG=$HOME/.kube/bsides-lab.conf`).

| Script | Called by | Phase | Does |
|---|---|---|---|
| `25-cilium-lb-ipam.sh` | `make lb`, CI `install-cilium` | 1 | LoadBalancer IP pool + L2 announcement |
| `30-install-tetragon.sh` | `make tetragon`, `make lab` | 2 | Tetragon 1.4.0 via Helm (+ tetra CLI locally) |
| `40-install-kubevirt.sh` | `make kubevirt` | 3 🚧 | KubeVirt operator + CR, nested-virt check, virtctl |

---

## `25-cilium-lb-ipam.sh`

Gives `type: LoadBalancer` Services (and Gateways) real IPs on the home LAN,
using Cilium instead of MetalLB. **MetalLB must not be installed alongside it**:
both would answer ARP for the same addresses.

Creates two Cilium objects:

**`CiliumLoadBalancerIPPool bsides-lab-pool`**: hands out `10.1.1.240`–`10.1.1.249`.

- Those IPs must be free and **outside the DHCP range**. Prod uses `.50–.52`,
  `.60–.64`, `.90–.93`; the lab nodes use `.40–.41`.

**`CiliumL2AnnouncementPolicy bsides-lab-l2`**: makes those IPs reachable by
answering ARP for them.

- `nodeSelector`: only nodes with `node-role.kubernetes.io/control-plane`, so
  the ARP owner is always `10.1.1.40` and `arping` gives the same answer on
  every run.
- `interfaces`: `^ens[0-9]+$` and `^eth[0-9]+$`. Check the real NIC name with
  `ssh ubuntu@10.1.1.40 ip -br addr`; if it matches neither, nothing is announced.
- `externalIPs: true`, `loadBalancerIPs: true`: announce both kinds.

It relies on the Cilium install flags `l2announcements.enabled=true` and a
raised `k8sClientRateLimit`. L2 announcements do leader election through
Kubernetes Leases, and at the default client rate limit the IPs flap.

Idempotent: it's a `kubectl apply`, so rerun it any time. (Its comment about
"all three nodes" dates from an earlier three-node design; the cluster has two.)

## `30-install-tetragon.sh`

```bash
helm upgrade --install tetragon cilium/tetragon --version 1.4.0 -n kube-system \
  --set tetragon.enableProcessCred=true \
  --set tetragon.enableProcessNs=true
```

- `enableProcessCred` / `enableProcessNs` add process credentials (uid/gid,
  capabilities) and namespace info to events, useful when explaining *who* ran
  something.
- Waits for `ds/tetragon` to roll out.
- Installs the `tetra` CLI **on the machine running the script** if it's missing.
  It downloads the *latest* release, not 1.4.0. You rarely need it locally:
  the talk uses the `tetra` inside the Tetragon pod
  (`kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents ...`),
  and `install-master-deps.yml` puts a pinned `tetra` v1.4.0 on the master.
- Override the version with `TETRAGON_VERSION=x.y.z make tetragon`.
- Needs the `helm.cilium.io` repo reachable.

## `40-install-kubevirt.sh` 🚧

1. Picks `KUBEVIRT_VERSION`. **Via `make kubevirt` this is pinned to `v1.9.0`**
   (the Makefile exports it), matching the `virtctl` that
   `install-master-deps.yml` puts on the master. Run the script *directly* and
   it falls back to whatever
   `storage.googleapis.com/kubevirt-prow/.../stable.txt` says today.
2. Applies the KubeVirt operator and the `KubeVirt` CR from GitHub releases.
3. **Nested virtualisation check**: SSHes to the worker (`10.1.1.41`, hard-coded,
   with your own SSH key) and looks for `vmx`/`svm` in `/proc/cpuinfo`. If
   missing, it prints two options:
   - enable nesting on the Proxmox host (`kvm-intel nested=Y`, then reboot or
     reload the module), or
   - patch KubeVirt to `useEmulation: true` (software emulation, which works but
     is slow: the VM takes about 4 minutes to boot instead of about 1).
   It only warns; it doesn't stop.
4. Waits up to 15 min for the `KubeVirt` CR to become `Available`.
5. Installs `virtctl` locally if it's missing, using the same version.

Needs GitHub reachable from wherever you run it, and a working SSH key to the worker.
