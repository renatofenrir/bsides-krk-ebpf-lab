# Phase 3 — KubeVirt ✅ *(validated 2026-09-21/22, hardened 2026-09-23/24)*

The closing argument of the talk:

> **Network policy follows the workload into a VM. Process-level enforcement
> does not.** Same attack, same policy, different kernel — so you move the
> sensor up into the guest. And then you monitor the sensor, because in the
> guest it sits inside the attacker's blast radius.

Every step here was run on this cluster. Full runbook with expected output:
[`LAB_GUIDE.md` §3](../LAB_GUIDE.md).

## The five beats

| Beat | What happens | Evidence |
|---|---|---|
| 1 | A VM on Kubernetes: `virt-launcher` pod, normal pod IP, normal Cilium endpoint | `kubectl -n kubevirt-demo get vmi,pods` |
| 2 | Phase 2's kill policy is on. The same `tcpdump` **survives in the VM** but **exits 137 in a pod** on the same node | measured |
| 3 | The host's Tetragon shows **zero** events for the guest's processes | measured |
| 4 | Load the *same* policy inside the guest → `tcpdump` there **exits 137** | measured |
| 5 | The catch: in-guest sensors are tamperable; the host keeps network identity and the hypervisor boundary | talking point |

## Files

| File | Role |
|---|---|
| `10-nginx-vm.yaml` | namespace + `VirtualMachine nginx-vm`; cloud-init comes from a Secret |
| `cloud-init/nginx-vm-user-data.yaml` | **the real cloud-config**: nginx, nmap, tcpdump, Tetragon in the guest, the staged policy, `load-policy.sh`/`unload-policy.sh` |
| `20-service.yaml` | ClusterIP Service in front of the VM |
| `40-tmp-client.yaml` | netshoot pod; the Service test target, and the jump host for the ssh fallback |
| `30-gateway-httproute.yaml` | 🚧 **parked, unvalidated** — needs Gateway API, which Cilium has off |
| `50-cnp-l4.yaml` | 🚧 **parked, but validated standalone 2026-09-24** — the old `/secret` demo's L4 step; not applied by `make kubevirt`, not part of the talk, confirmed working on its own (see below) |
| `60-cnp-l7.yaml` | 🚧 **parked, unvalidated** — the L7 step; needs the Gateway to route through Envoy, so it's untestable while Gateway API is off |

`make kubevirt` installs KubeVirt (pinned **v1.9.0**), creates the cloud-init
Secret from the file above, and applies `10`, `20`, `30`, `40`. Applying `30`
is harmless: with Gateway API off it simply does nothing.

`make kubevirt-ready` blocks until cloud-init has actually finished (polls
`/guest-ready`), and `make kubevirt-test` checks both access paths in one
shot — the Service (works) and the Gateway (stays `Pending`, no address —
expected, not a bug).

## What's in the guest, and why it's pre-baked

cloud-init installs and stages, so nothing slow or network-dependent happens on stage:

- **nginx** serving `/`, `/details`, `/secret` (kept from the old draft; only `/details` gets mentioned) and `/guest-ready`, the marker that says cloud-init finished.
- **nmap and tcpdump** — the Phase 2 toolkit, at `/usr/bin`, so the *same* attacks run inside the guest.
- **Tetragon 1.4.0**, same version as the cluster, as a systemd service, **with no policies loaded**. That is the "host sensor can't see in here" state the demo opens with. The standalone tarball's `install.sh` also drops the **`tetra` CLI** — confirmed present 2026-09-24 — so beat 4 can query the guest's own Tetragon locally (`sudo tetra getevents -o compact`) and show the identical `🚀 process`/`💥 exit ... SIGKILL` event style beat 2 showed from the host, just sourced from inside the guest. See `LAB_GUIDE.md` §3.4.
- **`/etc/tetragon/tetragon.conf.d/disable-kprobe-multi`** — mandatory, see gotchas.
- **`/root/policies/kill-tcpdump.yaml`** — the guest's copy of Phase 2's policy, staged but not loaded. Keep it in sync with `../phase2-container-lab/policies/20-kill-tcpdump.yaml`.
- **`/usr/local/bin/load-policy.sh`** — beat 4: copies the policy into `/etc/tetragon/tetragon.tp.d/`, restarts Tetragon and **waits until the kprobe is attached** before returning.
- **`/usr/local/bin/unload-policy.sh`** — the encore: removes the policy and restarts Tetragon clean, so beat 4 can be repeated (load → killed, unload → survives) without a VM rebuild between cycles. Standalone Tetragon only reads its policy directory at startup, so unloading needs a restart too — no live unload in this mode.

## Reaching the guest

**Primary: the console.** No key file needed — just the `virtctl`/`kubectl`
access you already have:

```bash
virtctl console nginx-vm -n kubevirt-demo
# login: ubuntu   password: whatever you exported as VM_CONSOLE_PASSWORD before `make kubevirt`
```

Log in once and leave the terminal attached; every beat's command is typed
directly at that shell. `Ctrl+]` detaches without killing the session — the
same `virtctl console` command picks it back up. The password is **never
committed** — `cloud-init/nginx-vm-user-data.yaml` has a template placeholder
that `make kubevirt` renders from the `VM_CONSOLE_PASSWORD` env var at apply
time (it refuses to run without it set); see gotchas below if login fails.

**Fallback: ssh**, if you have the matching private key (the **public** half
is in the cloud-config; the private half is never committed):

```bash
export VMIP=$(kubectl -n kubevirt-demo get vmi nginx-vm -o jsonpath='{.status.interfaces[0].ipAddress}')
kubectl -n kubevirt-demo exec -i tmp-client -- sh -c 'cat > /tmp/vmkey && chmod 600 /tmp/vmkey' < /path/to/private/key
vm() { kubectl -n kubevirt-demo exec tmp-client -- ssh -i /tmp/vmkey -o StrictHostKeyChecking=no ubuntu@$VMIP "$* ; echo exit=\$?"; }
```
then every guest command is `vm <command>`. The trailing `; echo exit=$?` runs
*inside* the guest's shell, so the exit code printed is always the real one —
never ssh's own `255` for "the remote process was killed by a signal".

Full walkthrough with expected exit codes for both paths:
[`LAB_GUIDE.md` §3](../LAB_GUIDE.md#30--before-you-start).

## Gotchas found while validating

- **Tetragon in the guest needs `disable-kprobe-multi` too.** Without it the
  daemon dies (`Failed to start tetragon … bpf_multi_kprobe_v61.o … load
  program: invalid argument`) the moment a policy is loaded, and the attack
  "survives" because the sensor is dead — the most misleading possible failure
  for this particular demo.
- **`load-policy.sh` must wait for the hook.** A plain `sleep 3` after the
  restart wasn't enough: the first `tcpdump` still survived, the second was
  killed. It now polls for `Added kprobe` and takes ~4 s.
- **Inline cloud-init is capped at 2048 bytes** by KubeVirt; this config is
  ~4.7 KB, hence the Secret. Editing the file does nothing until the Secret is
  rebuilt **and** the VM restarted (`kubectl -n kubevirt-demo delete vmi nginx-vm`).
- **The field is `secretRef`**, not `userDataSecretRef`.
- **The console password is templated, never committed.** The cloud-config has
  `ubuntu:__VM_CONSOLE_PASSWORD__`; `make kubevirt` substitutes it from the
  `VM_CONSOLE_PASSWORD` env var into a temp file before building the Secret,
  and refuses to run without it set. "Login incorrect" means the running VM
  was built with a different value (or before this existed) —
  `make kubevirt-reset` with the variable exported rebuilds it correctly.
- **Exit codes over the ssh fallback:** `137` = killed, `124` = your `timeout`
  fired, i.e. survived, `255` = ssh couldn't express the signal. Run
  `...; echo exit=$?` inside the guest for the true code. The console doesn't
  have this problem — it's a plain shell, so `echo exit=$?` is always accurate.
- **Don't run pod attacks while demoing beat 3** — their events appear in the
  host stream and read like guest events. (Only relevant if you also drove the
  guest over ssh in the same window: `ssh … tcpdump` shows the word "tcpdump"
  in the host stream as part of the *ssh process's* argv.)
- **`spec.running` is deprecated** in favour of `runStrategy`; it still works.
- **`tmp-client` used an implicit `Always` pull policy.** `nicolaka/netshoot:latest`
  with no explicit `imagePullPolicy` defaults to `Always` on a `:latest` tag,
  so every `make kubevirt-reset` re-pulled from Docker Hub live even with the
  image already cached. Measured 2026-09-25 in Phase 2's identical setup: a
  TLS handshake timeout to Docker Hub took down a rehearsal. Now pinned to
  `IfNotPresent` — only rescues *repeats*, so get one working pull cached
  before you rely on it.
- **The guest's disk is small and fixed-size** (plain `containerDisk`, no
  CDI/DataVolume in this cluster — can't be enlarged from the VM spec).
  Measured 2026-09-24: leaving the downloaded Tetragon tarball and its
  extracted tree on disk after `install.sh` copied the binaries out was
  enough to hit `No space left on device` on the very next write. cloud-init
  now deletes both right after install, disables apt recommends before
  `nginx`/`nmap`/`tcpdump`, runs `apt-get clean`, and caps the journal at
  50 MB. See `LAB_GUIDE.md` §3.6 for the live recovery commands if it ever
  fills up anyway.

## Bonus check: L4 network policy still applies (not part of the talk)

Confirmed 2026-09-24, standalone, without touching anything above:

```bash
kubectl apply -f phase3-kubevirt-lab/50-cnp-l4.yaml
kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/details   # still works -- explicitly allowed
kubectl run cnp-test --rm -it --image=nicolaka/netshoot -n kubevirt-demo --restart=Never \
  -- wget -qO- --timeout=3 http://nginx/details                             # times out -- not in the allow-list
kubectl delete -f phase3-kubevirt-lab/50-cnp-l4.yaml                        # clean up -- back to exactly where you started
```

Confirms Cilium enforces `CiliumNetworkPolicy` on `nginx-vm`'s pod exactly
like any other workload. Not added to the talk because the talk's argument
is process-level enforcement following the VM, not network policy — this was
just never in question and is here for your own Q&A backup. See
`50-cnp-l4.yaml`'s header for the full reasoning, and `LAB_GUIDE.md` §3.6.

## Reset between rehearsals

```bash
export VM_CONSOLE_PASSWORD=<same or new value>   # kubevirt refuses to run without it
make kubevirt-reset    # kubevirt-clean + kubevirt in one shot
make kubevirt-ready    # blocks until cloud-init is done
make kubevirt-test     # Service works; Gateway stays Pending (expected)
```

Or step by step:

```bash
make kubevirt-clean    # drops the kubevirt-demo namespace; KubeVirt stays installed
make kubevirt          # Secret + VM + client again (~1-2 min to ready)
```
