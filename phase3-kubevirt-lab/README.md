# Phase 3 — KubeVirt ✅ *(validated 2026-09-21/22)*

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
| `cloud-init/nginx-vm-user-data.yaml` | **the real cloud-config**: nginx, nmap, tcpdump, Tetragon in the guest, the staged policy, `load-policy.sh` |
| `20-service.yaml` | ClusterIP Service in front of the VM |
| `40-tmp-client.yaml` | netshoot pod; also the jump host for reaching the guest over ssh |
| `30-gateway-httproute.yaml` | 🚧 **parked** — needs Gateway API, which Cilium has off |
| `50-cnp-l4.yaml`, `60-cnp-l7.yaml` | 🚧 **parked** — the old `/secret` demo, not part of the talk |

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
- **Tetragon 1.4.0**, same version as the cluster, as a systemd service, **with no policies loaded**. That is the "host sensor can't see in here" state the demo opens with.
- **`/etc/tetragon/tetragon.conf.d/disable-kprobe-multi`** — mandatory, see gotchas.
- **`/root/policies/kill-tcpdump.yaml`** — the guest's copy of Phase 2's policy, staged but not loaded. Keep it in sync with `../phase2-container-lab/policies/20-kill-tcpdump.yaml`.
- **`/usr/local/bin/load-policy.sh`** — beat 4: copies the policy into `/etc/tetragon/tetragon.tp.d/`, restarts Tetragon and **waits until the kprobe is attached** before returning.

## Reaching the guest (no console needed)

Once, per terminal session:

```bash
export VMIP=$(kubectl -n kubevirt-demo get vmi nginx-vm -o jsonpath='{.status.interfaces[0].ipAddress}')
kubectl -n kubevirt-demo exec -i tmp-client -- sh -c 'cat > /tmp/vmkey && chmod 600 /tmp/vmkey' < /path/to/private/key
vm() { kubectl -n kubevirt-demo exec tmp-client -- ssh -i /tmp/vmkey -o StrictHostKeyChecking=no ubuntu@$VMIP "$* ; echo exit=\$?"; }
```

then every guest command is `vm <command>`, e.g. `vm sudo tcpdump -i any -c 3`.
The trailing `; echo exit=$?` runs *inside* the guest's shell, so the exit code
printed is always the real one — never ssh's own `255` for "the remote process
was killed by a signal". Full walkthrough with expected exit codes:
[`LAB_GUIDE.md` §3](../LAB_GUIDE.md#30--before-you-start).

The **public** key is in the cloud-config; the private half is never committed.
`virtctl console nginx-vm -n kubevirt-demo` also works if you have virtctl (the
control plane does).

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
- **Exit codes over ssh:** `137` = killed, `124` = your `timeout` fired, i.e.
  survived, `255` = ssh couldn't express the signal. Run
  `...; echo exit=$?` inside the guest for the true code.
- **Don't run pod attacks while demoing beat 3** — their events appear in the
  host stream and read like guest events. Also, `ssh … tcpdump` shows the word
  "tcpdump" in the host stream as part of the *ssh process's* argv.
- **`spec.running` is deprecated** in favour of `runStrategy`; it still works.

## Reset between rehearsals

```bash
make kubevirt-reset    # kubevirt-clean + kubevirt in one shot
make kubevirt-ready    # blocks until cloud-init is done
make kubevirt-test     # Service works; Gateway stays Pending (expected)
```

Or step by step:

```bash
make kubevirt-clean    # drops the kubevirt-demo namespace; KubeVirt stays installed
make kubevirt          # Secret + VM + client again (~1-2 min to ready)
```
