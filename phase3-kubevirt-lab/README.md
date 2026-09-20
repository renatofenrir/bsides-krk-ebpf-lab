# Phase 3 — KubeVirt 🚧 DRAFT

A real VM (Ubuntu + nginx) running inside the cluster, locked down first at L4
and then at L7 with CiliumNetworkPolicy. The point: to the datapath, a VM is
just another pod, so the same policy language applies to it.

> **Nothing in this folder has ever been run**, not at a talk and not on this
> cluster. Rehearse all of it, and be ready to skip it. Phase 2 stands on its own.

## ⚠️ Read first: Gateway API is currently off

On 2026-09-14 the lab's Cilium was switched to **Gateway API disabled**, to
match prod. With it enabled, Cilium 1.18.1's operator crash-loops on the
Gateway API v1.5.1 CRDs, and the cluster has no networking at all.

What that means here:

| Part | Works? |
|---|---|
| VM, Service, `tmp-client`, L4 policy, L7 policy **from `tmp-client`** | yes, none of it needs Gateway API |
| `30-gateway-httproute.yaml` | applies, but **does nothing**: no `cilium` GatewayClass exists, so the Gateway never gets an address |
| Anything using `$GATEWAY` (curl from the laptop) | **no** |
| The `fromEntities: ingress` rules in `50`/`60` | harmless, but unused |

To get the external/Gateway half back you need a Cilium version whose operator
supports Gateway API v1.5.1 (and, to keep matching prod, the same upgrade in
prod). Until then, run Phase 3 from `tmp-client` only.

## Files

| File | What it is |
|---|---|
| `10-nginx-vm.yaml` | namespace `kubevirt-demo` + `VirtualMachine nginx-vm` |
| `20-service.yaml` | ClusterIP Service `nginx` → the VM on port 80 |
| `30-gateway-httproute.yaml` | Gateway `nginx-gw` + HTTPRoute (inactive, see above) |
| `40-tmp-client.yaml` | `tmp-client` netshoot pod, the in-cluster client |
| `50-cnp-l4.yaml` | CiliumNetworkPolicy `vm-l4-lockdown` |
| `60-cnp-l7.yaml` | CiliumNetworkPolicy `vm-l7-lockdown` |

`make kubevirt` installs KubeVirt ([`scripts/40-install-kubevirt.sh`](../scripts/))
and applies `10`–`40`. You apply `50` and `60` by hand during the demo. The
numbers are the apply order.

---

## `10-nginx-vm.yaml` — the VM

An Ubuntu 24.04 VM (`quay.io/containerdisks/ubuntu:24.04`, 1 core, 1536M). Its
cloud-init installs nginx and serves three paths:

| Path | Content | Meant to be |
|---|---|---|
| `/` | stock nginx welcome page | allowed |
| `/details` | `<h1>VMDetails</h1>` + hostname, IP, locale (rendered at boot) | allowed |
| `/secret` | `<h1>TOP SECRET</h1><p>flag{ebpf-runtime-security}</p>` | blocked by L7 |

Things to know:

- **Labels on the template** (`app: nginx`, `kubevirt.io/vm: nginx-vm`) end up
  on the **`virt-launcher-nginx-vm-*` pod**. That pod is what Services, Cilium
  and Tetragon see.
- **`masquerade` networking.** The guest sits behind NAT inside the launcher
  pod's network namespace. The guest thinks its IP is `10.0.2.2`, while the
  cluster routes to the pod IP. Policies act on the pod IP. That's why
  `/details` shows `10.0.2.2`.
- **Boot it before going on stage.** cloud-init runs `apt install nginx`, which
  needs egress and takes minutes (more under software emulation). Watch with
  `kubectl -n kubevirt-demo get vmi -w`; debug with
  `virtctl console nginx-vm -n kubevirt-demo`.
- **Tetragon can't see inside the VM.** Processes in the guest run on the
  guest's own kernel. From the node, Tetragon only sees the QEMU process in
  `virt-launcher`. Cilium network policy still applies, because it enforces at
  the launcher pod's network interface. That split is worth a sentence in the talk.
- `spec.running: true` works, but newer KubeVirt releases prefer
  `runStrategy: Always` and may print a deprecation warning.

## `20-service.yaml` — Service

Plain ClusterIP Service `nginx`, selector `kubevirt.io/vm: nginx-vm`, port
80→80. Nothing KubeVirt-specific: that's the point.

## `30-gateway-httproute.yaml` — Gateway (inactive)

A Cilium-class Gateway listening on HTTP/80, plus one HTTPRoute sending `/` (as
a prefix, so everything) to the `nginx` Service. It **does no access control
on purpose**: blocking `/secret` in the route would prove nothing about eBPF.
The decision belongs to the CiliumNetworkPolicy. It would take its external IP
from the LB pool `10.1.1.240–249`. Currently inactive; see the warning at the top.

## `40-tmp-client.yaml` — client

A netshoot pod in `kubevirt-demo`, `sleep infinity`, used as
`kubectl exec tmp-client -n kubevirt-demo -- curl ...`. Its `curl` is exactly
what Phase 2's cluster-wide kill policy kills, so run `make unmitigate` first.

---

## The policies

Both are **ingress** policies selecting the VM's launcher pod
(`kubevirt.io/vm: nginx-vm`). Once a policy selects an endpoint for ingress,
**anything not explicitly allowed is dropped** (default deny for that direction).

### `50-cnp-l4.yaml` — `vm-l4-lockdown`

Allows TCP/80 from:

1. pods labelled `app: tmp-client` (`fromEndpoints`)
2. the Gateway's Envoy (`fromEntities: ingress`)

Everything else to the VM is dropped.

**The beat:** this is the policy a normal Kubernetes team writes, and it's
correct. But `GET /details` and `GET /secret` are both just "TCP to port 80"
at L4, so:

```bash
kubectl exec tmp-client -n kubevirt-demo -- curl --fail -s http://nginx/secret   # works: the gap
```

### `60-cnp-l7.yaml` — `vm-l7-lockdown`

Same two sources and port, plus `rules.http`: only `GET ^/$` and
`GET ^/details$` are allowed. Anything else, including `/secret`, is answered
by Cilium's Envoy proxy with **`403 Forbidden`** (`server: envoy`). nginx never
receives the request: tail the VM console next to the curl to show it.

```bash
kubectl delete cnp vm-l4-lockdown -n kubevirt-demo      # FIRST, see below
kubectl apply -f 60-cnp-l7.yaml
kubectl exec tmp-client -n kubevirt-demo -- curl --fail -s http://nginx/details   # allowed
kubectl exec tmp-client -n kubevirt-demo -- curl -s -o /dev/null -w '%{http_code}\n' http://nginx/secret  # 403
```

Seen from Hubble:

```
kubevirt-demo/tmp-client -> kubevirt-demo/virt-launcher-nginx-vm-xxxxx:80 http-request DROPPED (HTTP/1.1 GET http://nginx/secret)
```

**Rules that matter:**

- **Delete the L4 policy first.** When several policies select the same
  endpoint, Cilium allows the **union** of everything they allow. `50` allows
  all of TCP/80 from `tmp-client` with no HTTP rules, so while it exists
  `/secret` stays reachable no matter what `60` says.
- **How `path` matching really works (this corrects the comments in the
  YAML and in `LAB_GUIDE.md` §3.5).** Cilium passes `path` to Envoy as a
  `safe_regex` on the request's `:path`
  (`pkg/envoy/policy/envoy_l7_rules_translator.go` in Cilium 1.18.1), and
  Envoy's `safe_regex` must match the **whole** path. So an unanchored `"/"`
  matches only `/` exactly; it would **not** let `/secret` through, contrary to
  the "unanchored gotcha" described in the comments. The `^…$` anchors are
  harmless but redundant. Don't build a slide on that gotcha without seeing it
  reproduce in rehearsal; it most likely won't. The real consequence of
  full-match is the opposite:
  - `/details?x=1` is **denied**, because the query string is part of `:path`.
    Use `^/details(\?.*)?$` if you want query strings allowed.
  - `/details/` (trailing slash) is **denied**.

---

## Order of play

```bash
make kubevirt                                    # KubeVirt + 10-40 (runs make unmitigate first)
kubectl -n kubevirt-demo get vmi -w              # wait for Running, then give cloud-init a few minutes
kubectl exec tmp-client -n kubevirt-demo -- curl -s http://nginx/details    # baseline
kubectl apply -f phase3-kubevirt-lab/50-cnp-l4.yaml
kubectl exec tmp-client -n kubevirt-demo -- curl -s http://nginx/secret     # L4 gap: still works
kubectl delete cnp vm-l4-lockdown -n kubevirt-demo
kubectl apply -f phase3-kubevirt-lab/60-cnp-l7.yaml
kubectl exec tmp-client -n kubevirt-demo -- curl -s -o /dev/null -w '%{http_code}\n' http://nginx/secret  # 403
```

## Still unproven

- Nested virtualisation for these guests (`make preflight` checks `vmx`/`svm`).
  Without it KubeVirt needs `useEmulation: true`, which is slow.
- `socketLB.hostNamespaceOnly=true` together with KubeVirt masquerade has not
  been exercised on this cluster.
- The `/details` renderer is reconstructed from observed output.
- The whole Gateway half, blocked on Gateway API (above).

## Cleanup

```bash
kubectl delete namespace kubevirt-demo
```
