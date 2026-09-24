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
| 🚧 **PARKED** | Written, not part of the talk | `30-gateway-httproute.yaml`, `50-cnp-l4.yaml`, `60-cnp-l7.yaml` — none applied by `make kubevirt`, none part of the demo beats |

Phase 3's demo path — VM, in-guest Tetragon, the kill — was run end to end on
this cluster on 2026-09-21/22, then hardened (console access, disk-space fix,
repeatable policy toggle) on 2026-09-23/24, and is ✅. Of the parked files,
`30-` and `60-` are also **unvalidated** (both blocked on Gateway API being
off); `50-cnp-l4.yaml` was separately confirmed working standalone on
2026-09-24 — parked from the talk, not untested. See its own header comment
and `phase3-kubevirt-lab/README.md`.

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
| 3 — KubeVirt | ~8 min live | **Yes — VM booted in advance, Tetragon pre-installed in the guest** |

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
- [ ] `10.1.1.40` and `.41` are free. Prod holds `.50–.52` (masters),
      `.60–.64` (workers), `.90–.93` (GPU).
- [ ] `10.1.1.240–249` are free and **outside the DHCP scope** — that is the
      LoadBalancer pool.
- [ ] Nested virtualisation is on, for Phase 3:
      `cat /sys/module/kvm_intel/parameters/nested` → `Y`
- [ ] The `local-lvm` thin pool has room for 2 × 80 GB. Prod notes had
      `sleipnir`'s pool at 77% — check before adding 160 GB.

```bash
export TF_VAR_pm_user='root@pam'
export TF_VAR_pm_password='...'          # never put these in tfvars
export MINIO_ACCESS_TOKEN='...'          # Terraform state backend
export MINIO_SECRET_KEY='...'
cp vms/terraform.tfvars.example vms/terraform.tfvars
$EDITOR vms/terraform.tfvars              # set template_vm_id + ssh_public_key
```

Everything runs in containers — the same Kubespray and Terraform images the
prod pipeline uses — so the laptop needs only `docker`, `ansible`, `ssh`,
`kubectl` and `make`.

> **Isolation note.** This repo shares nothing with
> `k8s-playground-bootstrapper`: different state file, different inventory,
> different hostnames, different IPs. Prod (`bifrost-prod-v4`) cannot be
> touched from here. If you ever see `bifrost-prod` in a plan or an inventory
> in this repo, stop.

---

## Phase 1 — Reprovision the cluster

The whole phase is one command:

```bash
make up      # vms → cluster → untaint → kubeconfig → crds → cilium → lb → components
```

Each step below is also its own target, which is what you want when something
goes wrong mid-build — `make` picks up where it stopped rather than starting
over. `make help` lists them all, and
[`MAKE_TARGETS.md`](./MAKE_TARGETS.md) documents the exact command each one
runs, what it needs first, and what it changes.

### 1.1 — Clone the VMs

```bash
make plan    # read-only, safe to run any time
make vms
```

Expected plan:

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

Anything with a destroy in it, or any hostname containing `bifrost-prod`, means
the wrong state key got loaded. Stop — this repo writes to `bsides-krk-lab/`,
never `bifrost-prod/`.

`make vms` also waits for SSH and for cloud-init to settle, so the next step
does not start against a half-booted guest.

### 1.2 — Bootstrap Kubernetes (no CNI, no kube-proxy)

```bash
make cluster     # runs install-master-deps.yml, then Kubespray cluster.yml
make untaint     # control plane becomes schedulable
make kubeconfig
export KUBECONFIG=$HOME/.kube/bsides-lab.conf
```

`make cluster` first puts helm, the Cilium CLI, hubble, tetra and virtctl on
the control plane, so the entire talk can be driven from one SSH session on
`10.1.1.40` with no tooling on the presenting laptop. On a conference network,
the fewer things that must work on your machine, the fewer ways the demo dies.

**`make untaint` is not optional.** Kubespray taints the control plane
`NoSchedule`. On a two-node cluster that leaves exactly one schedulable node,
every Hubble flow becomes node-local, and the part of the demo that shows
traffic crossing a node boundary silently stops being true.

Takes 20–30 minutes. When it finishes:

```console
$ kubectl get nodes
NAME                           STATUS     ROLES           AGE   VERSION
k8s-master-0-bsides-krk-demo   NotReady   control-plane   2m    v1.35.4
k8s-worker-0-bsides-krk-demo   NotReady   <none>          1m    v1.35.4
```

**`NotReady` is correct here.** There is no CNI yet. CoreDNS will be `Pending`
for the same reason. This is deliberate: installing Cilium by hand is Phase 1's
payoff shot, and `ipam.mode` cannot be changed after an install, so it has to
be right the first time.

### 1.3 — Gateway API CRDs, then Cilium

```bash
make crds      # MUST come first
make cilium
```

**Gateway API is off in Cilium, same as prod.** The CRDs are installed (v1.5.1,
also prod's), but `gatewayAPI.enabled=true` crash-loops Cilium 1.18.1's
operator: it asks for TLSRoute `v1alpha2`, which v1.5.1 no longer serves, and
the agents then wait forever for the operator, so no pod gets networking.
Phase 3's Gateway/HTTPRoute step needs a Cilium release that understands
v1.5.1 before it can work.

`make crds` is a targeted apply of just `module.gateway_api_crds` against the
components stack — the same trick prod's `bootstrap-crds` stage uses. The rest
of the add-ons wait for `make components`, because with no CNI yet they would
only sit `Pending`. The module vendors the Gateway API manifests rather than
fetching them from GitHub at apply time, so a venue network that cannot reach
`raw.githubusercontent.com` does not stop the build.

`make cilium` runs, from the control plane:

```bash
cilium install --version 1.18.1 \
  --set cluster.name=default \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set l2announcements.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set socketLB.hostNamespaceOnly=true \
  --set k8sServiceHost=10.1.1.40 \
  --set k8sServicePort=6443 \
  --set k8sClientRateLimit.qps=50 \
  --set k8sClientRateLimit.burst=200
```

`cluster.name=default` pins prod's cluster name: left to auto-detection,
`cilium install` picks `cluster-local`, a later upgrade picks `default`, and
Hubble Relay rejects the agents' TLS certs over the mismatch. The next six
flags are ✅ from the original lab (it also had `gatewayAPI.enabled=true`,
dropped above). The last four are additions, and both pairs are load-bearing:

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

DaemonSet              cilium             Desired: 2, Ready: 2/2, Available: 2/2
DaemonSet              cilium-envoy       Desired: 2, Ready: 2/2, Available: 2/2
Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay       Desired: 1, Ready: 1/1, Available: 1/1
Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
```

(Two of everything: this cluster has two nodes. The `cilium-operator`
Deployment runs two replicas, one per node.)

```console
$ kubectl get nodes
NAME                           STATUS   ROLES           AGE   VERSION
k8s-master-0-bsides-krk-demo   Ready    control-plane   8m    v1.35.4
k8s-worker-0-bsides-krk-demo   Ready    <none>          7m    v1.35.4
```

### 1.4 — LoadBalancer IPs, L2 announcement, add-ons

```bash
make lb
make components
```

This replaces MetalLB. **The two cannot coexist** — both would ARP for the same
addresses. That is why this lab installs no add-on stack at all, unlike prod,
where `bifrost-k8s-extensions-module` brings MetalLB along.

Confirm the announcing interface is right — the policy matches `^ens[0-9]+$`
and `^eth[0-9]+$`, and Ubuntu cloud images on virtio usually present `ens18`:

```bash
ssh ubuntu@10.1.1.40 ip -br addr
```

`make components` then applies the rest of the add-on stack — metrics-server,
local-path as the default StorageClass, and the CoreDNS forward for the
`example.com` zone. The same modules prod uses, but **vendored** into
`components/modules/` rather than fetched: this repo depends on no other repo,
so neither a venue network that cannot reach home nor prod moving its module
repo forward can change what the lab installs.

### 1.5 — Pre-flight checklist

Run this the night before and again in the speaker room:

```bash
make preflight
```

which checks Cilium, the nodes, the static kprobe symbols on both hosts, and
nested virtualisation for Phase 3. The kprobe check matters more than it looks
— see the Phase 2 note on static symbols.

---

## Phase 2 — The container demo ✅ *(previously presented)*

### 2.1 — Install Tetragon

```bash
make tetragon
```

Tetragon has never been part of your add-on stack — it is not in
`bifrost-k8s-extensions-module` — so this is a fresh install, not a re-deploy.

### 2.2 — Deploy the attacker

```bash
make lab        # installs Tetragon too, if you skipped the step above
kubectl -n tetragon-demo get pods -o wide
```

`nicolaka/netshoot` ships nmap, curl, nc, tcpdump and dig — exactly the toolkit
the policies are written against. The pod sleeps as PID 1 and attacks run via
`kubectl exec`, so a SIGKILL never takes the pod down and you never lose your
shell mid-sentence. The attacker is pinned to the worker and the victim to the
(untainted) control plane, so flows cross a node boundary and show up as
inter-node traffic in Hubble. On a two-node cluster those two hostnames are the
whole topology — if `make untaint` did not run, the victim sits `Pending` and
this is where you find out.

### 2.3 — Detection

**Terminal 2** — leave this streaming for the whole demo:

```bash
make events     # streams from the Tetragon pod on the ATTACKER'S node, filtered to that pod
```

> **Tetragon events are per node.** `kubectl exec ds/tetragon` picks a single
> pod — here the control plane's — while the attacker runs on the worker, so
> the attacks never appear and the stream fills with unrelated kube-system
> activity (nodelocaldns running `iptables`, and so on). That is what `make
> events` used to do. It now resolves the attacker's node first. By hand:
> ```bash
> kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon -o wide   # find the worker's pod
> kubectl -n kube-system exec <that-pod> -c tetragon -- tetra getevents -o compact --pod attacker
> ```
> Also remember `🚀 process` / `💥 exit` lines are Tetragon's built-in process
> events for **every** exec on that node. They are not policy hits. Policy hits
> from this phase look like `🔌 connect` or `❓ syscall`.

**Terminal 1:**

```bash
make detect
```

⚠️ **RECONSTRUCTED**, but **validated on this cluster** (2026-09-20, and again
in a full dry run on 2026-09-22): the in-cluster API call stayed silent, the
`nmap` below produced **six** connect events — three ports × the two live hosts,
`.42` does not exist — and the external curl one, for **seven** in total. The CIDRs in it — `10.233.0.0/18` (services)
and `10.233.64.0/18` (pods) — are pinned in
`inventory/group-vars/all/all.yml`. If you ever change those, change the policy
or it flags every in-cluster connection as suspicious.

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
make mitigate
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

**Exit code 137 = 128 + 9 = SIGKILL.** All three were confirmed on this cluster
on 2026-09-20, along with `nmap -sS` (also 137) and `wget` (exit 0 — busybox,
so not on the kill list; use it for an "allowed traffic still works" beat).

Terminal 2, as actually observed:

```
🚀 process tetragon-demo/attacker /usr/bin/nmap -sT -p 22,6443 10.1.1.40-41
❓ syscall tetragon-demo/attacker /usr/bin/nmap raw_sendmsg
💥 exit    tetragon-demo/attacker /usr/bin/nmap -sT -p 22,6443 10.1.1.40-41 SIGKILL
🚀 process tetragon-demo/attacker /usr/bin/tcpdump -i any -c 5
❓ syscall tetragon-demo/attacker /usr/bin/tcpdump security_socket_create
💥 exit    tetragon-demo/attacker /usr/bin/tcpdump -i any -c 5 SIGKILL
```

Each kill prints the hook that fired. `tetra -o compact` renders these kprobe
events as `❓ syscall`, not as pretty connect lines.

**Which hook actually kills what** (measured, and *not* what the original notes
claimed):

| Attack | Killed at | Why |
|---|---|---|
| `nmap -sT` | `raw_sendmsg` | host discovery sends raw probes before any TCP connect |
| `nmap -sT -Pn` | `ip_send_skb` | discovery skipped, but nmap still emits its own datagrams |
| `nmap -sS` | `raw_sendmsg` | SYN scan builds its own packets |
| `curl https://example.com` | `ip_send_skb` | the DNS lookup goes out first, as UDP |
| `curl http://10.1.1.41:22` | `tcp_connect` | no DNS, so the TCP connect is the first packet |
| `tcpdump` | `security_socket_create` | fires before a socket exists |

**The line to say on stage:** the *earliest* hook wins. With four hooks
attached, the process dies at whichever one it trips first — for nmap that is
raw packet transmission, long before `tcp_connect`. tcpdump is the extreme
case: `security_socket_create` runs before a socket exists, so it dies with no
network activity at all.

**If you want the "one connect event, then the kill" visual**, use
`curl http://10.1.1.41:22` (an IP, so no DNS lookup first). Note it prints the
connect line **twice** while both the detection and the kill policy are
applied: both hook `tcp_connect`, and each policy reports the event.

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
> policy sits there doing nothing. This is why it is in the pre-flight checklist.
> Both were present on 2026-09-20, and all five hooks attached cleanly.
>
> ⚠️ **A policy can fail to load with no sign of it in `kubectl`.** The
> TracingPolicy CRD has **no status field**, so `kubectl get/describe
> tracingpolicy` looks healthy whatever happened. On 2026-09-20 every policy on
> this cluster silently did nothing, because Tetragon 1.4.0's **kprobe-multi**
> BPF object does not load on kernel 7.0.0-31-generic:
> ```
> adding tracing policy failed ... bpf_multi_kprobe_v61.o ...
> program generic_kprobe_event: load program: invalid argument
> ```
> `scripts/30-install-tetragon.sh` now installs with
> `--set tetragon.extraArgs.disable-kprobe-multi=true` (single kprobes, which
> work) and fails loudly if any policy fails to load. **The only way to see
> this class of failure is the agent log:**
> ```bash
> kubectl -n kube-system logs ds/tetragon -c tetragon | grep "adding tracing policy failed"
> ```

### 2.4b — Rehearsing the same run repeatedly

Phase 2 is meant to be rehearsed until the outcome is boring. One cycle takes
about **50 seconds**, almost all of it waiting for the namespace to delete:

```bash
make lab-reset     # lab-clean + lab: policies and pods removed, then redeployed
make detect        # then the three attacks
make mitigate      # then the kills
make unmitigate    # back to the detection-only state
```

| Target | Removes | Keeps |
|---|---|---|
| `make lab-clean` | all three TracingPolicies (and the namespaced variant), attacker, victim, namespace | Tetragon, the cluster |
| `make lab-reset` | the above, then redeploys Phase 2 | Tetragon, the cluster |
| `make lab-purge` | the above **and** uninstalls Tetragon | the cluster |
| `make kubevirt-clean` | Phase 3's `kubevirt-demo` namespace and policies | KubeVirt itself |
| `make reset` | **DESTRUCTIVE: the whole Kubernetes install** (Kubespray `reset.yml`) | the VMs |

`lab-clean` waits for the namespace to finish terminating before returning, so
a following `make lab` can't race a namespace still going away.

For an unattended loop, set `SKIP_TETRA_CLI=1` so the Tetragon script never
tries to `sudo` a local CLI install:

```bash
SKIP_TETRA_CLI=1 make lab-reset
```

Two full cycles were run this way on 2026-09-20, plus a complete dry run of
both phases on 2026-09-22, all with identical results: the in-cluster call
stayed silent, detection reported one connect event per scanned port plus one
for the external curl (5 with the two-port `nmap`, 7 with the three-port one in
§2.3), and `nmap -sT`, `nmap -sS`, `curl`, `tcpdump` and `nc` all exited 137
while `wget` kept working. A reset cycle measured 51 s.

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

## Phase 3 — KubeVirt ✅ *(validated 2026-09-21/22, hardened 2026-09-23/24)*

**The argument:** network policy follows the workload into a VM; process-level
enforcement does not. Same attack, same policy, different kernel — so you move
the sensor up into the guest.

Every step below was run end to end on this cluster. What is **not** part of
the talk any more: the Gateway, the HTTPRoute and the L4/L7
CiliumNetworkPolicies (`30-`, `50-`, `60-`). Those files stay in the repo,
unused — Cilium has Gateway API off, and the argument above does not need
them. (`50-cnp-l4.yaml` specifically was separately confirmed to still work
standalone on 2026-09-24 — see §3.6 — it's excluded from the talk on
narrative grounds, not because it's broken.)

### 3.0 — Before you start

```bash
export VM_CONSOLE_PASSWORD=<pick one>   # the ubuntu login for the VM's console -- never committed
make kubevirt                           # KubeVirt v1.9.0 + cloud-init Secret + the VM + tmp-client
```

`make kubevirt` refuses to run without `VM_CONSOLE_PASSWORD` set. It renders
`cloud-init/nginx-vm-user-data.yaml`'s `__VM_CONSOLE_PASSWORD__` placeholder
with that value before building the Secret — the committed file never
contains a real password, same as this repo's Proxmox/MinIO credentials.
Pick anything memorable; it only protects a lab VM's serial console.

**Open three terminals before you go anywhere near the stage. This is the
whole runbook's layout — every beat below just tells you which one to type
in.**

| Terminal | For | First command |
|---|---|---|
| **1** | Driving `make`/`kubectl` from your laptop | (whatever the beat says) |
| **2** | The host's Tetragon event stream (beat 3 only) | `make events-vm` |
| **3** | **Attached to the guest's console — log in once, leave it open** | `virtctl console nginx-vm -n kubevirt-demo` |

**Terminal 3, once, at the start of Phase 3:**
```bash
virtctl console nginx-vm -n kubevirt-demo
```
Press Enter if nothing appears (the console is a live stream, not a replay —
this is expected on an already-booted VM). Log in with `ubuntu` and whatever
you exported as `VM_CONSOLE_PASSWORD`:

```
nginx-vm login: ubuntu
Password: <your VM_CONSOLE_PASSWORD>
```

Leave this terminal attached and logged in for the rest of Phase 3 — beats 2,
3 and 4 all just type a command directly at this same guest shell prompt. If
you ever need to detach without killing the session, `Ctrl+]` does it; the
guest's shell keeps running and `virtctl console nginx-vm -n kubevirt-demo`
picks the same session back up.

This needs **no private key on your laptop** — only the `kubectl`/`virtctl`
access you already have to run the command at all. (There is a second way in
over ssh, `kubectl -n kubevirt-demo exec tmp-client -- ssh ...`, documented in
`phase3-kubevirt-lab/README.md`; it needs the matching private key, which is
never committed to this repo, so treat it as a fallback, not the plan.)

⚠️ **"Login incorrect" almost always means the running VM predates
`VM_CONSOLE_PASSWORD`** — either it was booted before this was added, or with
a different value than you're typing now. Rebuild it with the same variable
exported and it picks up the current value:
```bash
export VM_CONSOLE_PASSWORD=<same or new value>
make kubevirt-reset      # kubevirt-clean + kubevirt, re-renders the Secret
make kubevirt-ready       # wait for it to come back
```
Then retry the `virtctl console` login above.

Other prerequisites, all confirmed here:

- **Nested virtualisation**: the worker's Ryzen 5 5600G reports `svm` on all 4
  CPUs, so the VM runs at full speed. `make preflight` checks this.
- **`make kubevirt` runs `make unmitigate` first.** Phase 2's cluster-wide kill
  policy SIGKILLs `curl`, which breaks anything driving the VM with curl. In
  the demo below the kill policies come back on deliberately, at beat 2.
- **Boot the VM well before you go on stage.** cloud-init installs nginx, nmap,
  tcpdump *and Tetragon in the guest*. It took ~20–100 s here; assume minutes.
  `make kubevirt-ready` blocks until it's actually done.

**`kubectl get gateway` shows `nginx-gw` stuck `Pending` with no address.**
That is expected and harmless: Gateway API is off in Cilium, so no controller
ever looks at it. Nothing in the demo uses it. `make kubevirt-test` checks both
paths in one shot — Service works, Gateway stays `Pending` — so this doesn't
read as a broken run mid-rehearsal (re-confirmed empty on 2026-09-23: `export
GATEWAY=$(kubectl -n kubevirt-demo get gateway nginx-gw -o
jsonpath='{.status.addresses[0].value}')` prints nothing, by design). Delete
the Gateway before the talk if a stray listing would distract:
`kubectl -n kubevirt-demo delete -f phase3-kubevirt-lab/30-gateway-httproute.yaml`

**Reading exit codes in this phase:** `137` = SIGKILL (the policy worked).
`124` = your own `timeout` expired, i.e. **the process survived**. Typing
directly at the Terminal 3 console shell (as below) always shows the real exit
code with a plain `echo exit=$?` — the ssh-specific `255`/`Killed` confusion
only applies if you go the ssh-fallback route instead.

### 3.1 — Beat 1: a VM is just a workload

```console
$ kubectl -n kubevirt-demo get vmi
NAME       AGE   PHASE     IP              NODENAME
nginx-vm   10m   Running   10.233.65.148   k8s-worker-0-bsides-krk-demo

$ kubectl -n kubevirt-demo get pods
virt-launcher-nginx-vm-zt9gs   2/2   Running
```

A normal pod, a normal pod IP, a normal Cilium endpoint.

```bash
kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/details
```

reaches it through an ordinary Service. (Use `wget`, not `curl`, once the kill
policies are on — Phase 2's `mitigate` SIGKILLs `curl` cluster-wide.) The guest
believes its IP is `10.0.2.2` — that is KubeVirt's masquerade NAT inside the
launcher pod.

### 3.2 — Beat 2: the attack that just died in a container

**Terminal 1** — turn Phase 2's enforcement back on:

```bash
make mitigate     # cluster-wide kill policies, as in Phase 2
```

**Prove it's actually loaded before you run either attack.** `make mitigate`
only *applies* the TracingPolicy objects — it does not confirm the kprobe is
attached, and a policy can sit there "applied" but inert (see §3.6 and the
`preflight` gotcha). Two checks, ~15 s apart, still in **Terminal 1**:

```bash
kubectl get tracingpolicy
# expect: kill-network-recon-binaries, kill-tcpdump   (both cluster-wide, no namespace)

kubectl -n kube-system logs ds/tetragon -c tetragon --tail=50 | grep -i tcpdump
# expect a line like "... msg=\"Added kprobe\" ... symbol=\"security_socket_create\" ..."
# nothing? wait a few more seconds -- the hook takes a moment to attach.
```

Now run the *same* attack in both places:

**Terminal 1** — the pod, on the node the VM is running on:
```bash
kubectl -n tetragon-demo exec attacker -- tcpdump -i any -c 3; echo exit=$?
```
Expect kubectl itself to print `command terminated with exit code 137`, then
`exit=137` (same as §2.4 — kubectl detects the signal and reports it directly,
no wrapper needed).

**Terminal 3** — the identical attack, typed directly at the guest's console
(you're already logged in from §3.0). Deliberately **no `-c`** here — see the
note below:
```
sudo timeout 6 tcpdump -i any; echo exit=$?
```
Expect `exit=124` — `timeout` is what stops it, 6 s later, because nothing in
the guest kernel does.

> ⚠️ **Don't add `-c 3` back on this one.** With a packet count, `tcpdump`
> races `timeout`: the guest's own ARP/DNS chatter usually delivers 3 packets
> in well under 6 s, so `tcpdump` exits **0** on its own before `timeout` ever
> fires — a real, measured outcome, not a mistake if you see it. Dropping `-c`
> removes the race: nothing but the 6 s deadline can end it, so `exit=124` is
> the only possible result. Either way the number that matters is what's
> **absent** — `137` never appears, because nothing killed it.

| Where | Terminal | Result |
|---|---|---|
| pod (`attacker`) | 1 | `exit=137` — killed |
| VM (`nginx-vm`) | 3 | `exit=124` — survives |

Same binary, same policy, same node. Only the kernel differs.

### 3.3 — Beat 3: why the host sensor is blind

**Terminal 2** — stream the host's Tetragon on the VM's own node:

```bash
make events-vm
```

That resolves `nginx-vm`'s node, finds the Tetragon pod running there, and
streams it scoped with `--pod` to the VM's own `virt-launcher` pod — same
pattern as Phase 2's `make events`, just keyed to the VM instead of the
attacker pod.

**What "working" looks like: near-total silence.** Terminal 2 should sit
almost empty. If you instead see a wall of `nodelocaldns`, `kubelet` or other
`kube-system` lines, you ran plain `tetra getevents` unscoped — `make
events-vm` filters those out on purpose (see `MAKE_TARGETS.md`). Don't chase
that noise if you ever see it; it's unrelated host chatter, not a sign
anything's broken.

**Terminal 3** — with the stream running, type the attack directly at the
guest's console:

```
sudo tcpdump -i any -c 3
sudo nmap -sT -p 22,80 localhost
```

**Expect Terminal 2 to print nothing at all for these two commands.** That
silence — scoped to the exact pod running your VM, not "zero events somewhere
in a noisy stream" — *is* the beat: the host sees `qemu` sitting there, not the
processes inside the guest, because they never touch the host kernel. `Ctrl+C`
stops the stream in Terminal 2 once you've made the point.

> Careful when you demo this: if a pod runs the same attack in the same window,
> its events *do* appear and look like guest events. Run the guest attack alone
> in Terminal 3, nothing else, while Terminal 2 is watching.

### 3.4 — Beat 4: move the sensor up

Tetragon is already installed in the guest (cloud-init, same 1.4.0 as the
cluster), running with **no policies loaded**. Drop in the *same* policy file
Phase 2 uses — **Terminal 3**, same console session as beats 2 and 3:

```
sudo /usr/local/bin/load-policy.sh
```
Expect: `policy loaded and hook attached after ~4s`.

**Show the kill in the same event style as beat 2's `make events`.** The
guest's own Tetragon can be queried locally with `tetra` — confirmed present
here (`which tetra`) — no second terminal needed: background it in this same
console session, run the attack, then print what it caught:

```
sudo tetra getevents -o compact > /tmp/tetra-guest.log 2>&1 &
sudo timeout 6 tcpdump -i any -c 3; echo exit=$?
sudo pkill -f "tetra getevents"
cat /tmp/tetra-guest.log
```
Expect `exit=137`, and the log's `tcpdump` line to end in `SIGKILL` — the
*exact* event style Terminal 1 printed for the `attacker` pod in beat 2, just
sourced from the guest's own sensor instead of `kubectl exec`. (`-c 3` is
fine to keep here, unlike beat 2: the kill fires at `security_socket_create`,
before any packet is ever captured, so there's no race for a count to win.)

That script copies `/root/policies/kill-tcpdump.yaml` into
`/etc/tetragon/tetragon.tp.d/`, restarts the service, and **waits until the
kprobe is attached** — without that wait the first attack after the restart
still succeeds for a few seconds and the demo looks broken.

Note `nmap` still runs in the guest: only the tcpdump policy was loaded there.

```
sudo nmap -sT -p 22,80 localhost; echo exit=$?
```
Expect: `exit=0` — nmap was never targeted, so it's unaffected.

That is a useful detail if someone asks — the guest enforces exactly what you
gave it, nothing more.

**Repeating this beat.** Standalone Tetragon only reads
`/etc/tetragon/tetragon.tp.d/` at startup, so — same as loading it — removing
the policy needs a restart too; there's no live unload in this mode. Still
**Terminal 3**:

```
sudo /usr/local/bin/unload-policy.sh
```
Expect: `policy removed, tetragon restarted clean after ~2s`.

```
sudo tetra getevents -o compact > /tmp/tetra-guest.log 2>&1 &
sudo timeout 6 tcpdump -i any; echo exit=$?
sudo pkill -f "tetra getevents"
cat /tmp/tetra-guest.log
```
Expect `exit=124` — survives again, same as beat 2 (no `-c 3` here for the
same reason: nothing should end this run except the timeout). The log's
`tcpdump` line ends in a plain `0`, not `SIGKILL` — proof the sensor is
watching and simply has nothing to enforce right now, not that it's dead.

Toggle `unload-policy.sh` / `load-policy.sh` and repeat the matching capture
block as many times as makes the point — `SIGKILL` loaded, plain exit
unloaded, no VM rebuild between cycles.

### 3.5 — Beat 5: the catch

Close on the trade-off, not on the fix:

- A host sensor is **outside** the container's reach. An in-guest sensor is
  **inside** the attacker's blast radius — root in the guest can stop it.
- So the guest agent gets monitored too (heartbeats; KubeVirt supports vsock
  as a channel that does not depend on the guest's own networking).
- The host keeps what it is still authoritative for: **network identity and
  policy** for the VM, and the **hypervisor boundary** (`virt-launcher`/`qemu`
  integrity, escape attempts).

### 3.6 — Gotchas found while validating this

- **Tetragon in the guest hits the same kprobe-multi failure as the cluster.**
  Without `disable-kprobe-multi`, the daemon dies with `Failed to start
  tetragon ... bpf_multi_kprobe_v61.o ... load program: invalid argument` the
  moment a policy is dropped in — and the attack "survives" because the sensor
  is dead, not because the VM protected it. cloud-init writes
  `/etc/tetragon/tetragon.conf.d/disable-kprobe-multi` for this reason.
- **The cloud-config is too big to inline.** KubeVirt caps inline `userData` at
  2048 bytes; this one is ~4.7 KB, so it lives in the `nginx-vm-cloudinit`
  Secret, built from `cloud-init/nginx-vm-user-data.yaml`. Editing that file
  changes nothing until you rebuild the Secret **and** restart the VM:
  ```bash
  kubectl -n kubevirt-demo create secret generic nginx-vm-cloudinit \
    --from-file=userdata=phase3-kubevirt-lab/cloud-init/nginx-vm-user-data.yaml \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kubevirt-demo delete vmi nginx-vm      # the VM restarts itself
  ```
- **The field is `secretRef`**, not `userDataSecretRef`; the API rejects the latter.
- **`spec.running` is deprecated** in favour of `runStrategy`. It still works,
  it just warns on every apply.
- `make kubevirt` used to abort *after* installing KubeVirt but *before*
  applying the VM, because installing `virtctl` needs sudo. `SKIP_VIRTCTL=1`
  skips it, and a failure there no longer kills the run.
- **The console password is never committed.** `cloud-init/nginx-vm-user-data.yaml`
  has `ubuntu:__VM_CONSOLE_PASSWORD__`, a template placeholder; `make kubevirt`
  substitutes it from the `VM_CONSOLE_PASSWORD` env var into a temp file before
  building the Secret, and refuses to run if the variable is unset. "Login
  incorrect" means the running VM was built with a different value (or before
  this existed) — `make kubevirt-reset` with the variable exported fixes it.
  `ssh_pwauth: false` keeps sshd key-only regardless.
- **Beat 2's guest `tcpdump` raced its own `-c 3` against `timeout 6`.**
  Measured 2026-09-23: the guest's ambient ARP/DNS traffic delivered 3 packets
  in well under 6 s, so `tcpdump` hit its count and exited **0** on its own —
  a real "survived" result, but not the `exit=124` the guide predicted, and
  confusing if you're not expecting two valid outcomes. Fixed by dropping `-c`
  from that one command so `timeout` is unconditionally what ends it. Beat 4's
  `-c 3` doesn't have this problem — the kill there fires at
  `security_socket_create`, before any packet exists to count.
- **The guest ran out of disk mid-rehearsal (`No space left on device`),
  measured 2026-09-24, on a plain `cp` of a ~1 KB policy file at beat 4.**
  This VM's root disk is a plain `containerDisk` (no CDI/DataVolume in this
  cluster), so its size is fixed by the base image and **can't be bumped from
  the VM spec** — the fix is to stop wasting what it has. cloud-init now: (1)
  deletes the Tetragon tarball and its extracted tree right after
  `install.sh` copies the binaries into place — leaving both behind was
  duplicating that footprint for no reason; (2) sets
  `APT::Install-Recommends "false"` before `nginx`/`nmap`/`tcpdump` install;
  (3) runs `apt-get clean` at the end of `runcmd`; (4) caps the guest's
  journal at 50 MB so a long rehearsal day can't slowly fill the disk with
  logs. Needs the standard rebuild-Secret-and-restart-VM cycle to take effect
  on an already-running VM, same as any other cloud-init edit.

  **If it fills up again anyway**, at the console:
  ```bash
  df -h /
  sudo du -sh /var/cache/apt/archives /tmp/* 2>/dev/null
  sudo rm -rf /tmp/tetragon.tgz /tmp/tetragon-v1.4.0-amd64  # if still there
  sudo apt-get clean
  sudo journalctl --vacuum-size=20M
  df -h /
  ```
- **`50-cnp-l4.yaml` (parked, not applied by `make kubevirt`) was separately
  confirmed working, standalone, on 2026-09-24.** Applied by hand
  (`kubectl apply -f phase3-kubevirt-lab/50-cnp-l4.yaml`), it enforced
  correctly: `tmp-client` (explicitly allowed) still reached the VM, and a
  throwaway unlabeled pod (`kubectl run cnp-test --rm -it --image=nicolaka/netshoot
  -n kubevirt-demo --restart=Never -- wget -qO- --timeout=3 http://nginx/details`)
  timed out. Confirms Cilium enforces L4 `CiliumNetworkPolicy` on a KubeVirt
  workload's pod exactly like any other — it's excluded from the talk on
  narrative grounds (the argument here is process-level, not network
  policy), not because it doesn't work. Clean up after re-testing:
  `kubectl delete -f phase3-kubevirt-lab/50-cnp-l4.yaml`.

### 3.7 — Reset between rehearsals

```bash
export VM_CONSOLE_PASSWORD=<same or new value>   # kubevirt refuses to run without it
make kubevirt-reset     # kubevirt-clean + kubevirt in one shot
make kubevirt-ready     # blocks until cloud-init is done
make kubevirt-test      # Service works; Gateway stays Pending (expected)
```

Or step by step: `make kubevirt-clean` (drops the `kubevirt-demo` namespace;
KubeVirt itself stays) then `make kubevirt` (rebuilds Secret + VM + client).

---

## Teardown

```bash
make down
```

Prompts once, tears down the add-on stack best-effort, then destroys both VMs.
Prod is in a different repo with a different state key and is not touched.

Narrower options when you want them:

| | |
|---|---|
| `make reset` | Kubespray `reset.yml` — wipe Kubernetes, keep the VMs |
| `make destroy-components` | add-ons only |
| `make destroy-vms` | the two VMs only |
| `make clean` | local Terraform caches and the lab kubeconfig |

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
| Cluster | Deleted test cluster | `bsides-krk-demo`, 2 nodes (untainted master + worker), 10.1.1.40–41 |
| Reference lab base | Kind | Proxmox + Kubespray |
| Pod CIDR | `10.244.0.0/16` | `10.233.64.0/18` |
| Service CIDR | Kind default | `10.233.0.0/18` |
| Gateway IP | `172.18.255.200` | from `CiliumLoadBalancerIPPool`, 10.1.1.240–249 |
| LB mechanism | Kind + MetalLB | Cilium `l2announcements` (no MetalLB) |
| Cilium install | `cilium install --set ...` | same, plus `k8sServiceHost` and `k8sClientRateLimit` |
| TracingPolicies | 3, all validated | 1 verbatim, 2 reconstructed — **all three run on this cluster 2026-09-20/22** |
| VM section | none | Phase 3: VM + in-guest Tetragon, validated 2026-09-21/22, hardened 2026-09-23/24 |
