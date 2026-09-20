# Phase 2 — Tetragon TracingPolicies

The four policies the container demo is built on. This file explains what each
one hooks, what it matches, what it does, and what to watch out for on stage.

## Refresher: what a TracingPolicy is

Tetragon loads eBPF programs into the kernel of every node. A
`TracingPolicy` tells it **where** to attach (a kernel function, via a
*kprobe*), **which calls to care about** (*selectors*), and **what to do** when
one matches (*actions*).

```
kprobe (kernel function)  →  selectors (which process / which argument)  →  action
tcp_connect                   matchBinaries: /usr/bin/nmap                  Sigkill
```

- **No action** means *observe only*: Tetragon emits an event and nothing else happens.
- **`Sigkill`** means the kernel kills the process *inside the hooked call*,
  before that call returns. The action never completes. This is the "not a
  firewall" point of the talk: nothing is blocked on the wire; the process just
  stops existing mid-syscall.
- `TracingPolicy` is **cluster-wide**: every process on every node, including
  host processes. `TracingPolicyNamespaced` only applies to pods in its
  namespace.
- `matchBinaries` compares the **real path of the executable**, after symlinks
  are resolved. A tool that is a busybox applet is `/bin/busybox` to Tetragon,
  whatever it was called on the command line.

Exit code **137** in the terminal = 128 + 9 = killed by SIGKILL.

## At a glance

| File | Kind | Status | Hooks | Matches | Action |
|---|---|---|---|---|---|
| `00-monitor-outside-cluster-cidr.yaml` | TracingPolicy | ⚠️ reconstructed | `tcp_connect` | destination **not** in pod/service CIDR or loopback | observe |
| `10-kill-network-recon-binaries.yaml` | TracingPolicy | ⚠️ reconstructed | `tcp_connect`, `ip_send_skb`, `raw_sendmsg`, `packet_sendmsg` | nmap, curl, nc | **Sigkill** |
| `11-kill-network-recon-binaries-namespaced.yaml` | TracingPolicyNamespaced (`tetragon-demo`) | ⚠️ reconstructed, deviation | `tcp_connect`, `ip_send_skb` | nmap, curl, nc | **Sigkill** |
| `20-kill-tcpdump.yaml` | TracingPolicy | ✅ battle-tested | `security_socket_create` | tcpdump | **Sigkill** |

**Status labels:** *battle-tested* means presented at the Heineken Kraków
warm-up talk and known to work. *Reconstructed* means the original YAML was
lost with the deleted cluster and rebuilt from how it behaved, so the behaviour
should match but the YAML may differ.

**All four were run end to end on this cluster on 2026-09-20** (`00`, `10` and
`20` directly; `11` not yet). Detection and every kill behaved as intended —
but only after fixing a Tetragon loading problem, and the *hook* that kills is
often not the one the notes assumed. Both are covered below.

## How they're applied

| Command | Applies |
|---|---|
| `make detect` | `00` |
| `make mitigate` | `10` + `20` |
| `make unmitigate` | deletes `10` + `20` (**not** `11`, and **not** `00`) |
| by hand | `11`: `kubectl apply -f 11-kill-network-recon-binaries-namespaced.yaml` |

```bash
kubectl get tracingpolicies                              # 00, 10, 20
kubectl get tracingpoliciesnamespaced -n tetragon-demo   # 11
# Did it actually load? kubectl CANNOT tell you -- the CRD has no status field.
kubectl -n kube-system logs ds/tetragon -c tetragon | grep -E "Added kprobe|adding tracing policy failed"
```

> ### ⚠️ A policy can be "applied" and still be doing nothing
>
> On 2026-09-20 every policy here was silently inert: Tetragon 1.4.0's
> **kprobe-multi** BPF object does not load on this cluster's kernel
> (7.0.0-31-generic), and the agent logged
> `adding tracing policy failed … load program: invalid argument` while
> `kubectl describe tracingpolicy` showed a perfectly healthy object.
>
> The install script now passes
> `--set tetragon.extraArgs.disable-kprobe-multi=true`, which makes Tetragon
> attach single kprobes instead, and fails the install if any policy fails to
> load. If a demo ever "doesn't react", check the agent log first.

---

## `00-monitor-outside-cluster-cidr.yaml` — detection

**Name:** `monitor-network-activity-outside-cluster-cidr-range` · **Status:** ⚠️ reconstructed

**Purpose:** report every outbound TCP connection whose destination is
*outside the cluster*. This is the "before" beat of the demo: we see the attack,
we don't stop it yet.

**How it works:**

- **Hook: `tcp_connect`.** The kernel function behind every outbound TCP
  connection attempt, called before the SYN is sent. Its argument is the
  socket, which already carries the destination address.
- **Selector: `matchArgs` with `NotDAddr`.** Match when the destination address
  is **not** one of:
  - `127.0.0.1` (loopback)
  - `10.233.0.0/18` (service CIDR, `kube_service_addresses`)
  - `10.233.64.0/18` (pod CIDR, `kube_pods_subnet`)
- **No `matchActions`.** Observe only; the killing lives in `10` and `20`.
  Detection and mitigation are separate files so the talk can show "before" and
  "after" as two distinct steps.

**What you should see** with `tetra getevents -o compact -n tetragon-demo`:

| Command in the attacker pod | Event? | Why |
|---|---|---|
| `curl -sk https://kubernetes.default.svc.cluster.local/version` | no | goes to ClusterIP `10.233.0.1`, inside the service CIDR |
| `nmap -sT -p 22,6443,10250 10.1.1.40-42` | **yes** | node IPs are outside both CIDRs, so scanning your own control plane looks like scanning the internet (correct, and worth saying) |
| `curl https://example.com` | **yes** | external address |

**Watch out:**

- **The CIDRs are hard-coded.** They must equal `kube_pods_subnet` and
  `kube_service_addresses` in
  [`inventory/group-vars/all/all.yml`](../../inventory/group-vars/all/all.yml).
  Change one, change the other, or every in-cluster connection is flagged. (The
  comment inside the YAML says `ansible/group_vars/...`; that path is stale.)
- **Only TCP.** UDP (DNS lookups, `nmap -sU`) never calls `tcp_connect` and is
  invisible to this policy.
- **Cluster-wide, every process.** Host processes connecting to node IPs
  (kubelet, containerd pulling images, health checks) also match. Unfiltered,
  `make events` can be noisy. Filter on stage:
  `kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact -n tetragon-demo`.
- **It depends on a Cilium flag.** The "in-cluster `curl` stays quiet" row
  only holds because Cilium is installed with `socketLB.hostNamespaceOnly=true`.
  Without that flag, Cilium rewrites ClusterIP → backend inside `connect()`,
  *before* `tcp_connect` runs, so the policy would see the API server's real
  backend (`10.1.1.40:6443`, a node IP) and flag it. Keep the flag.

---

## `10-kill-network-recon-binaries.yaml` — mitigation, cluster-wide

**Name:** `kill-network-recon-binaries` · **Status:** ⚠️ reconstructed

**Purpose:** kill `nmap`, `curl` and `nc` the moment they put anything on the
network, however they try to do it.

**Kill list** (identical in all four hooks): `/usr/bin/nmap`, `/usr/bin/curl`,
`/usr/bin/nc`, `/bin/nc`, `/usr/bin/ncat`, `/usr/bin/netcat`.

**Four hooks, because one isn't enough:**

| # | Hook | Fires on | What it catches that the others don't |
|---|---|---|---|
| 1 | `tcp_connect` | outbound TCP connect | `nmap -sT`, `curl`, `nc host port` |
| 2 | `ip_send_skb` | IP datagrams leaving via the normal IP stack | UDP: `nmap -sU`, DNS lookups, `nc -u` |
| 3 | `raw_sendmsg` | sends on raw sockets | `nmap -sS`: a SYN scan builds its own packets and **never calls `tcp_connect`** |
| 4 | `packet_sendmsg` | sends on `AF_PACKET` sockets | link-layer injection (nmap can send raw Ethernet frames on Linux) |

The line to say on stage: *a policy hooked only at `tcp_connect` catches the
noisy scan and misses the quiet one.*

`packet_sendmsg`'s argument is typed `nop` ("it exists, don't decode it")
because Tetragon has no type for `struct socket *`. That's fine: the selector
matches on the binary, not the argument.

**What you should see** (measured 2026-09-20): `nmap`, `curl` and `nmap -sS`
all exit **137**. Each kill prints one `❓ syscall` line naming the hook that
fired — `tetra -o compact` has no pretty renderer for these — followed by the
`SIGKILL` exit.

**Which hook actually kills, which is *not* what the original notes said:**

| Attack | Dies at | Why |
|---|---|---|
| `nmap -sT` | `raw_sendmsg` | host discovery sends raw probes before any TCP connect |
| `nmap -sT -Pn` | `ip_send_skb` | discovery skipped, but nmap still sends its own datagrams |
| `nmap -sS` | `raw_sendmsg` | builds its own SYN packets |
| `curl https://example.com` | `ip_send_skb` | DNS lookup leaves first, as UDP |
| `curl http://10.1.1.41:22` | `tcp_connect` | no DNS, so TCP connect is the first packet |

So **nmap dies with zero connect events**, not one. The talking point survives
in a better form: with four hooks attached, the process dies at whichever fires
first, and for nmap that's raw packet transmission, well before `tcp_connect`.
For a "connect event, then kill" visual, use `curl http://<ip>:<port>`; it
prints the connect line **twice** while `00` and `10` are both applied, because
both hook `tcp_connect` and each reports it.

**Watch out:**

- **⚠️ `raw_sendmsg` and `packet_sendmsg` are static kernel symbols.** They are
  usually present, but not guaranteed on every kernel build. If either is
  missing, Tetragon rejects **the whole policy**: it looks applied and kills
  nothing. Check before the talk (`make preflight` does this):
  ```bash
  ssh ubuntu@10.1.1.40 'grep -wE "raw_sendmsg|packet_sendmsg" /proc/kallsyms'
  kubectl describe tracingpolicy kill-network-recon-binaries
  ```
- **curl dies for *any* destination**, in-cluster included, because its DNS
  lookup alone trips `ip_send_skb`. For an "allowed traffic still works" beat,
  use a tool that isn't on the list. In netshoot, `wget` is busybox
  (`/bin/busybox`), so it survives:
  `kubectl exec -n tetragon-demo attacker -- wget -qO- http://victim`
- **Cluster-wide + curl = Phase 3 breaks.** Phase 3 drives everything with
  `curl`. Run `make unmitigate` first (`make kubevirt` does it for you), or use
  `11` instead.
- **Paths checked against the image.** In `nicolaka/netshoot:latest`, `nmap`,
  `curl`, `nc` and `tcpdump` are real binaries under `/usr/bin` (checked
  2026-09-15), so the paths above match. `ncat`/`netcat` aren't installed; those
  entries are harmless extras. If you switch the attacker image, re-check with
  `readlink -f $(command -v nmap curl nc tcpdump)` inside the pod.

---

## `11-kill-network-recon-binaries-namespaced.yaml` — mitigation, one namespace

**Name:** `kill-network-recon-binaries` (kind `TracingPolicyNamespaced`, namespace `tetragon-demo`) · **Status:** ⚠️ reconstructed, **deviation** from the original talk

**Purpose:** the same kill list, but only for pods in `tetragon-demo`, so
Phase 2 and Phase 3 can run back to back without deleting policies.

**Differences from `10`:**

| | `10` (cluster-wide) | `11` (namespaced) |
|---|---|---|
| Scope | every process on every node | pods in `tetragon-demo` only |
| Hooks | 4 | **2** (`tcp_connect`, `ip_send_skb`) |
| `nmap -sS` (raw sockets) | killed | **likely survives**: no `raw_sendmsg` hook |
| AF_PACKET sends | killed | **likely survives**: no `packet_sendmsg` hook |
| Needs static symbols | yes | no |

**When to use which:** `10` is the stronger demo ("I ran nmap in a completely
unrelated namespace and it died"). `11` is the safer continuous run. Decide in
rehearsal, not on stage.

**Watch out:**

- **It shares its name with `10` but is a different kind.** `make unmitigate`
  does **not** remove it. Delete it explicitly:
  `kubectl delete tracingpolicynamespaced kill-network-recon-binaries -n tetragon-demo`
- It doesn't cover tcpdump; `20` is still cluster-wide if you apply it.
- If the quiet scan matters to you, test `nmap -sS` against this variant in
  rehearsal before relying on it.

---

## `20-kill-tcpdump.yaml` — mitigation, sniffing

**Name:** `kill-tcpdump` · **Status:** ✅ battle-tested (from the original lab notes)

**Purpose:** kill tcpdump before it captures a single packet.

**How it works:**

- **Hook: `security_socket_create`.** The LSM (Linux Security Module) hook that
  every `socket()` call passes through. Its arguments are `family`, `type` and
  `protocol`, all ints; they're declared so they appear in the events.
- **Selector:** `matchBinaries` `/usr/sbin/tcpdump` or `/usr/bin/tcpdump`
  (netshoot's is `/usr/bin/tcpdump`).
- **Action:** `Sigkill`.

**What you should see:** `tcpdump -i any -c 5` exits **137**, and
`tetra getevents` shows the process start and the `SIGKILL` exit, with **no
connect event in between**.

**The contrast with `10` is the point of the talk.** nmap dies *after* one
connect event; tcpdump dies with *none*. `security_socket_create` runs before a
socket even exists, so nothing is ever captured. **Where you hook decides how
much the attacker gets to do before the kill.**

**Watch out:** it matches *any* socket tcpdump creates, so even interface
listing (`tcpdump -D`) is killed. That's expected.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Policy applied, nothing happens at all | **kprobe-multi doesn't load on this kernel** (seen 2026-09-20) | `kubectl -n kube-system logs ds/tetragon -c tetragon \| grep "adding tracing policy failed"`; fix is `disable-kprobe-multi=true` |
| Attacks produce no events, others do | you're streaming from the **wrong node's** Tetragon pod (`ds/tetragon` picks one) | `make events`, or pick the pod on the attacker's node |
| Policy applied, nothing killed | a static symbol is missing and the whole policy was rejected | agent log as above, `grep -w raw_sendmsg /proc/kallsyms` |
| Tool not killed, policy fine | binary path differs (symlink / busybox / other image) | `tetra getevents` shows the real `binary`; compare with the kill list |
| Every in-cluster call flagged by `00` | CIDRs in `00` don't match `all.yml`, or `socketLB.hostNamespaceOnly` was dropped | compare with `inventory/group-vars/all/all.yml` and the Cilium flags |
| Event stream floods | `00` is cluster-wide and sees host processes | add `-n tetragon-demo` to `tetra getevents` |
| Phase 3 curls exit 137 | `10` still applied (or `11` and you're in `tetragon-demo`) | `make unmitigate`; delete `11` explicitly |

See also: [`../attack/`](../attack/) for the pods these run against, and
[`LAB_GUIDE.md` §2](../../LAB_GUIDE.md) for the stage run order.
