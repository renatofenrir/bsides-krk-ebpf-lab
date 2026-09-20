# Phase 2 — container runtime security with Tetragon ✅

The part of the talk that was already presented at the Heineken Kraków warm-up.
One namespace with an attacker and a victim, and Tetragon policies that first
**see** the attack and then **kill** it in the kernel.

```
phase2-container-lab/
├── attack/      the attacker + victim pods         → attack/README.md
└── policies/    the four TracingPolicies           → policies/README.md  (read this one)
```

## The story in four beats

| Beat | Command | What the audience sees |
|---|---|---|
| 1. Setup | `make lab` | Tetragon installed, `attacker` on the worker, `victim` on the control plane |
| 2. Detection | `make detect` | in-cluster calls are quiet; nmap and external curl show up as events |
| 3. Mitigation | `make mitigate` | nmap, curl, tcpdump exit **137** (SIGKILL) |
| 4. Hubble | `cilium hubble port-forward &` then `hubble observe --namespace tetragon-demo --follow` | the same traffic from the network side |

Keep this running in terminal 2 the whole time:

```bash
make events     # streams from the Tetragon pod on the attacker's node
```

**Tetragon events are per node.** `kubectl exec ds/tetragon` picks a single pod
— the control plane's here — while the attacker runs on the worker, so the
attacks never show up. `make events` resolves the attacker's node first, then
filters to that pod. `make events-all` is the old unfiltered behaviour.

`🚀 process` / `💥 exit` lines are Tetragon's built-in process events for every
exec on that node, not policy hits. Policy hits appear as `🔌 connect` (the
detection policy) or `❓ syscall` (the kill policies).

## The two ideas to land

1. **This isn't a firewall.** Nothing is blocked on the network. The kernel
   watches a behaviour (a socket being created, a connection starting) and
   kills the process inside that call.
2. **Hook choice decides how far the attacker gets.** `kill-tcpdump` hooks
   socket creation, so tcpdump dies with zero packets captured. The recon
   policy hooks `tcp_connect`, so nmap gets exactly one connection attempt
   before dying. A policy on `tcp_connect` alone would miss `nmap -sS`
   entirely, which is why the recon policy uses four hooks.

## Rehearsing

```bash
SKIP_TETRA_CLI=1 make lab-reset   # ~50s: removes Phase 2 and redeploys it
```

`make lab-clean` removes it without redeploying, `make lab-purge` also removes
Tetragon. **`make reset` is something else entirely** and wipes the Kubernetes
install.

## Before moving to Phase 3

The cluster-wide kill policy kills **curl**, and Phase 3 is driven by curl.
Run `make unmitigate` (`make kubevirt` does it automatically), or use the
namespaced variant `11` from the start. Details in
[`policies/README.md`](policies/README.md#11-kill-network-recon-binaries-namespacedyaml--mitigation-one-namespace).

## Prerequisites

- Cluster built (`make up`), Cilium healthy, control plane untainted.
- Tetragon 1.4.0 (`make tetragon`, via [`scripts/30-install-tetragon.sh`](../scripts/)).
- `make preflight` passing, especially the static kprobe symbol check.

Full stage run order with expected output: [`LAB_GUIDE.md` §2](../LAB_GUIDE.md).
