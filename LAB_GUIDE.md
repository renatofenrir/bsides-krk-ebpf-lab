# eBPF Runtime Security with Cilium & Tetragon — Lab Guide

**BSides Kraków.** Rebuild-from-scratch runbook for the demo cluster, the
already-presented container security demo, and the new KubeVirt section.

---

## Status legend

Every artefact in this repo carries one of three labels. They mean different
things on stage, so they are worth internalising before you rehearse.

| Label | Meaning | Where |
|---|---|---|
| ✅ **BATTLE-TESTED** | Presented at the Heineken Kraków warm-up talk and known to work | `kill-tcpdump` policy, Cilium flag set |
| ⚠️ **RECONSTRUCTED** | Original YAML was lost with the deleted cluster; rebuilt from described behaviour. Behaviour should match, byte-for-byte equivalence is not claimed | `monitor-outside-cluster-cidr`, `kill-network-recon-binaries` |
| 🚧 **DRAFT / UNVALIDATED** | Phase 3. Never run anywhere. Rehearse before showing | everything under `phase3-kubevirt-lab/` |

**The single most important thing in this document:** the CIDRs, LB range and
gateway IPs in the original notes came from a **Kind** cluster
(`10.244.0.0/16`, `172.18.255.200`). This lab runs on Proxmox with Kubespray
defaults. Every one of those numbers is different here, and copying the old
ones across produces policies that silently match nothing.

---

## Timing

| Phase | Wall clock | Can it be pre-baked? |
|---|---|---|
| 1 — provision | ~35–45 min | **Yes — do this the night before** |
| 2 — container demo | ~12 min live | Policies pre-applied, attacks live |
| 3 — KubeVirt | ~10 min live | VM must be booted in advance (~4 min boot) |

Phase 1 is not a stage activity. Provision the day before, verify with the
pre-flight checklist, and leave the cluster running.

---

## Phase 0 — Prerequisites

On the operator laptop:

```bash
# Tooling
cilium version --client     # Cilium CLI
kubectl version --client
helm version
terraform version           # >= 1.5
docker info                 # Kubespray runs in a container
```

Proxmox side, confirmed **before** you start:

- [ ] A plain Ubuntu template exists (the standard one, **not** the NVIDIA-baked
      one — this lab has no GPU nodes). Note its VMID.
- [ ] `10.1.1.40`, `.41`, `.42` are free. Prod holds `.50–.52` (masters),
      `.60–.64` (workers), `.90–.93` (GPU).
- [ ] `10.1.1.240–249` are free and **outside the DHCP scope** — that is the
      LoadBalancer pool.
- [ ] Nested virtualisation is on, for Phase 3:
      `cat /sys/module/kvm_intel/parameters/nested` → `Y`
- [ ] The `local-lvm` thin pool has room for 3 × 80 GB. Prod notes had
      `sleipnir`'s pool at 77% — check before adding 240 GB.

```bash
export TF_VAR_pm_user='root@pam'
export TF_VAR_pm_password='...'          # never put this in tfvars
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars        # set template_vm_id + ssh_public_key
```

> **Isolation note.** This repo shares nothing with
> `k8s-playground-bootstrapper`: different state file, different inventory,
> different hostnames, different IPs. Prod (`bifrost-prod-v4`) cannot be
> touched from here. If you ever see `bifrost-prod` in a plan or an inventory
> in this repo, stop.

---

## Phase 1 — Reprovision the cluster

### 1.1 — Clone the VMs

```bash
./scripts/00-provision-vms.sh
```

Expected plan:

```
Plan: 3 to add, 0 to change, 0 to destroy.
```

Anything with a destroy in it, or any hostname containing `bifrost-prod`, means
you are pointed at the wrong thing. The script pauses and makes you type
`apply` for exactly this reason.

### 1.2 — Bootstrap Kubernetes (no CNI, no kube-proxy)

```bash
./scripts/10-bootstrap-kubespray.sh
export KUBECONFIG=$PWD/ansible/artifacts/lab.kubeconfig
```

Takes 20–30 minutes. When it finishes:

```console
$ kubectl get nodes
NAME                           STATUS     ROLES           AGE   VERSION
k8s-master-0-bsides-krk-demo   NotReady   control-plane   2m    v1.31.4
k8s-worker-0-bsides-krk-demo   NotReady   <none>          1m    v1.31.4
k8s-worker-1-bsides-krk-demo   NotReady   <none>          1m    v1.31.4
```

**`NotReady` is correct here.** There is no CNI yet. CoreDNS will be `Pending`
for the same reason. This is deliberate: installing Cilium by hand is Phase 1's
payoff shot, and `ipam.mode` cannot be changed after an install, so it has to
be right the first time.

### 1.3 — Install Cilium

```bash
./scripts/20-install-cilium.sh
```

The script installs the Gateway API CRDs first — `gatewayAPI.enabled=true`
makes the Cilium operator watch resources whose CRDs must already exist, and
getting the order wrong produces a CrashLoopBackOff that reads like a Cilium
bug and is not one. Then:

```bash
cilium install --version 1.18.1 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set l2announcements.enabled=true \
  --set gatewayAPI.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set socketLB.hostNamespaceOnly=true \
  --set k8sServiceHost=10.1.1.40 \
  --set k8sServicePort=6443 \
  --set k8sClientRateLimit.qps=50 \
  --set k8sClientRateLimit.burst=200
```

The first seven flags are ✅ from the original lab. The last four are
additions, and both pairs are load-bearing:

- **`k8sServiceHost` / `k8sServicePort`** — kube-proxy is gone, so nothing has
  programmed the `10.233.0.1` ClusterIP. But Cilium needs the API server to
  start, and Cilium is what would program it. Pointing at the node IP breaks
  the cycle. (The prod repo carries the same workaround.)
- **`k8sClientRateLimit`** — `l2announcements` runs leader election through
  Leases, which is API-write-heavy. At the client-go default of 5 qps the
  agents get throttled and LB IPs flap: announced, withdrawn, re-announced.
  On stage that looks precisely like a broken demo.

Verify:

```console
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
```

```console
$ kubectl get nodes
NAME                           STATUS   ROLES           AGE   VERSION
k8s-master-0-bsides-krk-demo   Ready    control-plane   8m    v1.31.4
k8s-worker-0-bsides-krk-demo   Ready    <none>          7m    v1.31.4
k8s-worker-1-bsides-krk-demo   Ready    <none>          7m    v1.31.4
```

### 1.4 — LoadBalancer IPs and L2 announcement

```bash
./scripts/25-cilium-lb-ipam.sh
```

This replaces MetalLB. **The two cannot coexist** — both would ARP for the same
addresses. That is why this lab installs no add-on stack at all, unlike prod,
where `bifrost-k8s-extensions-module` brings MetalLB along.

Confirm the announcing interface is right — the policy matches `^ens[0-9]+$`
and `^eth[0-9]+$`, and Ubuntu cloud images on virtio usually present `ens18`:

```bash
ssh ubuntu@10.1.1.40 ip -br addr
```

### 1.5 — Pre-flight checklist

Run this the night before and again in the speaker room:

```bash
cilium status --wait
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium
ssh ubuntu@10.1.1.40 'grep -wE "raw_sendmsg|packet_sendmsg" /proc/kallsyms'
```

That last one matters more than it looks — see the Phase 2 note on static
symbols.

---

## Phase 2 — The container demo ✅ *(previously presented)*

### 2.1 — Install Tetragon

```bash
./scripts/30-install-tetragon.sh
```

Tetragon has never been part of your add-on stack — it is not in
`bifrost-k8s-extensions-module` — so this is a fresh install, not a re-deploy.

### 2.2 — Deploy the attacker

```bash
kubectl apply -f phase2-container-lab/attack/netshoot.yaml
kubectl -n tetragon-demo get pods -o wide
```

`nicolaka/netshoot` ships nmap, curl, nc, tcpdump and dig — exactly the toolkit
the policies are written against. The pod sleeps as PID 1 and attacks run via
`kubectl exec`, so a SIGKILL never takes the pod down and you never lose your
shell mid-sentence. The attacker is pinned to worker-0 and the victim to
worker-1, so flows cross a node boundary and show up as inter-node traffic in
Hubble.

### 2.3 — Detection

**Terminal 2** — leave this streaming for the whole demo:

```bash
kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact
```

**Terminal 1:**

```bash
kubectl apply -f phase2-container-lab/policies/00-monitor-outside-cluster-cidr.yaml
```

⚠️ **RECONSTRUCTED.** The CIDRs in it — `10.233.0.0/18` (services) and
`10.233.64.0/18` (pods) — are pinned in `ansible/group_vars/all/all.yml`. If
you ever change those, change the policy or it flags every in-cluster
connection as suspicious.

Now the three attacks:

```bash
# a) DNS-based recon against the API server
kubectl exec -n tetragon-demo attacker -- \
  curl -sk https://kubernetes.default.svc.cluster.local/version

# b) Network recon across the node subnet
kubectl exec -n tetragon-demo attacker -- \
  nmap -sT -p 22,6443,10250 10.1.1.40-42

# c) "Exfiltration" / payload fetch to something outside the cluster
kubectl exec -n tetragon-demo attacker -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://example.com
```

Terminal 2 shows the in-cluster call staying quiet and the outbound ones
lighting up:

```
🚀 process tetragon-demo/attacker /usr/bin/curl https://example.com
🔌 connect tetragon-demo/attacker /usr/bin/curl tcp 10.233.65.14:44120 -> 93.184.216.34:443
🚀 process tetragon-demo/attacker /usr/bin/nmap -sT -p 22,6443,10250 10.1.1.40-42
🔌 connect tetragon-demo/attacker /usr/bin/nmap tcp 10.233.65.14:39822 -> 10.1.1.40:6443
```

The point to make out loud: `10.1.1.40` is a *node* address. It is outside both
the pod and service CIDRs, so scanning your own control plane from a pod is
indistinguishable, to this policy, from scanning the internet. That is the
correct behaviour.

### 2.4 — Mitigation

```bash
kubectl apply -f phase2-container-lab/policies/10-kill-network-recon-binaries.yaml
kubectl apply -f phase2-container-lab/policies/20-kill-tcpdump.yaml
```

Re-run the same attacks:

```console
$ kubectl exec -n tetragon-demo attacker -- nmap -sT -p 22,6443 10.1.1.40-42
command terminated with exit code 137

$ kubectl exec -n tetragon-demo attacker -- curl -s https://example.com
command terminated with exit code 137

$ kubectl exec -n tetragon-demo attacker -- tcpdump -i any -c 5
command terminated with exit code 137
```

**Exit code 137 = 128 + 9 = SIGKILL.** Terminal 2:

```
🚀 process tetragon-demo/attacker /usr/bin/nmap -sT -p 22,6443 10.1.1.40-42
🔌 connect tetragon-demo/attacker /usr/bin/nmap tcp 10.233.65.14:39822 -> 10.1.1.40:22
💥 exit    tetragon-demo/attacker /usr/bin/nmap SIGKILL
🚀 process tetragon-demo/attacker /usr/sbin/tcpdump -i any -c 5
💥 exit    tetragon-demo/attacker /usr/sbin/tcpdump SIGKILL
```

Note the asymmetry, and say it: **nmap dies after one connect event, tcpdump
dies with none.** `kill-tcpdump` hooks `security_socket_create`, which fires
*before* a socket exists — the process is gone before a single packet is
captured. The recon policy hooks `tcp_connect`, which fires on the first
outbound connection, so exactly one attempt is visible before the kill. That
difference is the whole argument for choosing your hook point deliberately.

The `kill-network-recon-binaries` policy hooks four places on purpose:

| Hook | Catches |
|---|---|
| `tcp_connect` | outbound TCP — `nmap -sT`, curl, nc |
| `ip_send_skb` | any IP datagram — `nmap -sU`, DNS recon |
| `raw_sendmsg` | raw sockets — `nmap -sS` SYN scan |
| `packet_sendmsg` | AF_PACKET — link-layer injection |

A policy hooked only at `tcp_connect` catches the noisy scan and misses the
quiet one. `nmap -sS` builds packets itself and never calls `tcp_connect` at
all.

> ⚠️ **`raw_sendmsg` and `packet_sendmsg` are static kernel symbols.** They are
> usually in kallsyms but are not guaranteed on every build. If one is missing,
> Tetragon rejects the **whole** TracingPolicy rather than just that hook — the
> policy sits there doing nothing. Check with
> `kubectl describe tracingpolicy kill-network-recon-binaries`. This is why it
> is in the pre-flight checklist.

### 2.5 — Hubble, end to end

```bash
cilium hubble port-forward &
hubble observe --namespace tetragon-demo --follow
hubble ui                                    # opens the graph
```

Show the service map, then the flow list with the drops. The claim to land: the
kill decision and the flow record come from the same eBPF datapath, not from
two systems correlated after the fact.

---

## Phase 3 — KubeVirt 🚧 *(extended / new — NOT yet fully validated)*

> **Everything below this line is a draft.** It has not been run at a talk, and
> it has not been run on this cluster. Rehearse it end to end before showing
> it, and be ready to skip it. The Phase 2 material stands on its own.

### 3.0 — Before you start: the curl trap

Phase 2's `kill-network-recon-binaries` is **cluster-wide and kills curl**.
Phase 3 drives its entire demo with curl from `tmp-client`. Run them back to
back unchanged and every Phase 3 command dies with exit 137, for reasons that
have nothing to do with KubeVirt.

Pick one:

```bash
# Option A — drop the wide policy before Phase 3 (recommended on stage)
kubectl delete tracingpolicy kill-network-recon-binaries

# Option B — use the namespaced variant from the start of Phase 2 instead
kubectl apply -f phase2-container-lab/policies/11-kill-network-recon-binaries-namespaced.yaml
```

Option A gives the better Phase 2 demo — "I ran nmap in an unrelated namespace
and it died" lands harder than the scoped version. Option B lets you run both
phases continuously. Decide during rehearsal, not on stage.

### 3.1 — Install KubeVirt

```bash
./scripts/40-install-kubevirt.sh
```

Takes several minutes. The script checks for `vmx`/`svm` inside a guest and, if
nesting is off, prints the `useEmulation: true` fallback. Emulation is slow but
demos fine — the VM boots in maybe 4 minutes instead of 1.

```console
$ kubectl -n kubevirt get kv kubevirt
NAME       AGE   PHASE
kubevirt   6m    Deployed
```

### 3.2 — Boot the VM

```bash
kubectl apply -f phase3-kubevirt-lab/10-nginx-vm.yaml
kubectl -n kubevirt-demo get vmi -w
```

**Boot this before you go on stage.** cloud-init has to `apt install nginx`,
which needs working egress and takes minutes.

```console
$ kubectl -n kubevirt-demo get vmi
NAME       AGE   PHASE     IP             NODENAME
nginx-vm   4m    Running   10.233.65.42   k8s-worker-0-bsides-krk-demo
```

Console access if it misbehaves: `virtctl console nginx-vm -n kubevirt-demo`.

The beat worth making here: `kubectl get pods` shows a `virt-launcher-nginx-vm-*`
pod with a normal pod IP, a normal Cilium endpoint, and a normal identity. To
the datapath it is a workload like any other — which is exactly why the same
policy language works on it.

### 3.3 — Service and Gateway

```bash
kubectl apply -f phase3-kubevirt-lab/20-service.yaml
kubectl apply -f phase3-kubevirt-lab/30-gateway-httproute.yaml
kubectl apply -f phase3-kubevirt-lab/40-tmp-client.yaml

export GATEWAY=$(kubectl -n kubevirt-demo get gateway nginx-gw \
  -o jsonpath='{.status.addresses[0].value}')
echo "$GATEWAY"          # expect something in 10.1.1.240-249
```

> The original notes show `172.18.255.200`. That was Kind's Docker bridge.
> **Always read the real address out of the Gateway status** — never hardcode
> the old one into a slide.

Baseline, everything open:

```console
$ kubectl exec tmp-client -n kubevirt-demo -- curl --fail -s http://nginx/details
<h1>VMDetails</h1><p>Name: nginx-vm</p><p>IP: 10.0.2.2 </p><p>Locale: LANG=C.UTF-8 ...</p>

$ curl --fail -s http://$GATEWAY/ | head -4
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

`10.0.2.2` is the guest's own view of itself behind KubeVirt's `masquerade`
binding — the VM is NATed inside the virt-launcher pod's netns. Worth pointing
at: the address the VM believes it has and the address the cluster routes to
are different, and the policy operates on the latter.

### 3.4 — L4 lockdown

```bash
kubectl apply -f phase3-kubevirt-lab/50-cnp-l4.yaml
```

Only `tmp-client` and the Gateway may reach the VM, on TCP/80 only. Prove it,
then immediately show the gap:

```console
$ kubectl exec tmp-client -n kubevirt-demo -- curl --fail -s http://nginx/secret
<h1>TOP SECRET</h1><p>flag{ebpf-runtime-security}</p>
```

**The L4 policy is correct and it is not enough.** At L4, `GET /details` and
`GET /secret` are both "TCP to port 80" and it cannot tell them apart. That gap
is the argument for the next slide.

### 3.5 — L7 lockdown

```bash
kubectl delete cnp vm-l4-lockdown -n kubevirt-demo
kubectl apply -f phase3-kubevirt-lab/60-cnp-l7.yaml
```

> Delete the L4 policy first. Both select the same endpoint and Cilium takes
> the **union** of what they allow — leave the L4 rule in place and it keeps
> permitting the exact request the L7 rule exists to drop.

```console
$ kubectl exec tmp-client -n kubevirt-demo -- curl --fail -s http://nginx/details
<h1>VMDetails</h1><p>Name: nginx-vm</p><p>IP: 10.0.2.2 </p><p>Locale: LANG=C.UTF-8 ...</p>

$ curl --fail -s http://$GATEWAY/secret --verbose
> GET /secret HTTP/1.1
> Host: 10.1.1.240
< HTTP/1.1 403 Forbidden
< content-length: 15
< server: envoy
The requested URL returned error: 403
```

Terminal 2:

```
kubevirt-demo/tmp-client:48482 (ID:2272) -> kubevirt-demo/virt-launcher-nginx-vm-46qhw:80 (ID:27807) http-request DROPPED (HTTP/1.1 GET http://nginx/secret)
10.233.65.193:37405 (ingress) -> kubevirt-demo/virt-launcher-nginx-vm-46qhw:80 (ID:27807) http-request DROPPED (HTTP/1.1 GET http://172.18.255.200/secret)
```

Two things to say:

1. **`server: envoy`.** The 403 does not come from nginx. nginx never sees the
   request — show it by tailing the VM console next to the curl. Enforcement
   happens below the application, in the datapath, and the VM is not
   participating in its own defence.
2. **The path regexes are anchored** (`^/$`, `^/details$`). Cilium matches
   `path` as a regex, not a literal, so an unanchored `"/"` matches anything
   containing a slash — including `/secret`. The policy would apply cleanly and
   allow precisely the request it exists to block. Good "gotcha" slide material.

### 3.6 — What's still unproven in Phase 3

Be honest about this list if asked:

- Nested virt on the Proxmox host has not been confirmed for these guests.
- `socketLB.hostNamespaceOnly=true` is set for KubeVirt compatibility but that
  interaction has not been exercised here.
- The cloud-init `/details` renderer is reconstructed from observed output, not
  from the original manifest.
- Gateway API + `l2announcements` on bare metal is a different path from the
  Kind-based reference lab and has not been run end to end.

---

## Teardown

```bash
kubectl delete ns kubevirt-demo tetragon-demo --ignore-not-found
cd terraform && terraform destroy      # 3 VMs, local state, nothing shared
```

---

## Troubleshooting

**Nodes stay `NotReady` after `cilium install`.** Almost always
`k8sServiceHost`. With kube-proxy removed, `10.233.0.1` is unreachable until
Cilium programs it, and Cilium needs the API server first. Check
`kubectl -n kube-system logs ds/cilium` for connection refused to `10.233.0.1`.

**LB IP flaps / Gateway address keeps changing.** `k8sClientRateLimit` too low
for `l2announcements`. Check for client-side throttling in the agent logs.

**TracingPolicy applied but nothing is killed.**
`kubectl describe tracingpolicy <name>` — a missing static symbol
(`raw_sendmsg`, `packet_sendmsg`) rejects the entire policy, not just that hook.

**Everything in Phase 3 dies with exit 137.** You left Phase 2's cluster-wide
curl-kill policy applied. See §3.0.

**`/secret` is allowed despite the L7 policy.** Unanchored path regex. Must be
`^/secret$`-style anchoring — see §3.5.

**Working over Twingate from the venue.** Three known failure modes on this
setup, each with a different cause:

- *Authenticated but a host is unreachable* — check `/etc/hosts` first for a
  stale entry shadowing Twingate's DNS proxy. `resolvectl query <host>` showing
  `Data from: synthetic` is the tell.
- *Headers arrive, body hangs* — MTU blackhole over a relayed transport. Test
  with `sudo ip link set dev sdwan0 mtu 1280`. This one will look exactly like
  a broken demo, so check it during the pre-flight.
- *Constant re-auth prompts* — per-resource trust intervals, not a bug.
  Toggling WiFi off/on clears it faster than the browser flow.

---

## Appendix — differences from the original lab

| | Original (warm-up talk) | This lab |
|---|---|---|
| Cluster | Deleted test cluster | `bsides-krk-demo`, 1 master + 2 workers, 10.1.1.40–42 |
| Reference lab base | Kind | Proxmox + Kubespray |
| Pod CIDR | `10.244.0.0/16` | `10.233.64.0/18` |
| Service CIDR | Kind default | `10.233.0.0/18` |
| Gateway IP | `172.18.255.200` | from `CiliumLoadBalancerIPPool`, 10.1.1.240–249 |
| LB mechanism | Kind + MetalLB | Cilium `l2announcements` (no MetalLB) |
| Cilium install | `cilium install --set ...` | same, plus `k8sServiceHost` and `k8sClientRateLimit` |
| TracingPolicies | 3, all validated | 1 verbatim, 2 reconstructed |
