# `make` target reference — what each one actually runs

Every target in the `Makefile`, with the command it executes under the hood,
what it needs before it will work, and what it changes. `make help` prints the
one-line version.

Timings marked **(measured)** were taken on this cluster on 2026-09-20; the
rest are estimates from the build.

---

## The shared pieces

Four building blocks are reused by most targets.

### Variables (override on the command line, e.g. `make cilium CILIUM_VERSION=1.19.3`)

| Variable | Default | Used by |
|---|---|---|
| `KUBESPRAY_IMG` | `quay.io/kubespray/kubespray:v2.31.0` | `cluster`, `scale`, `reset` |
| `TF_IMG` | `renatofenrir/terraform:v7` | every Terraform target |
| `SSH_KEY` | `$(HOME)/.ssh/id_rsa` | Kubespray's container mount |
| `MASTER_IP` | `10.1.1.40` | `kubeconfig`, `cilium` |
| `CONTEXT` | `bsides-krk-demo` | `kubeconfig` (context rename) |
| `CILIUM_VERSION` | `1.18.1` | `cilium` (interpolated into the install command) |
| `TETRAGON_VERSION` | `1.4.0` | `tetragon` — **exported**, so the script sees it |
| `KUBEVIRT_VERSION` | `v1.9.0` | `kubevirt` — **exported**; pins the version instead of following `stable.txt` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `$(MINIO_ACCESS_TOKEN)` / `$(MINIO_SECRET_KEY)` | Terraform state backend |
| `VM_CONSOLE_PASSWORD` | **none — required** | `kubevirt`; the `ubuntu` login for `virtctl console nginx-vm`, templated into the cloud-init Secret at apply time, never committed |

Only the variables marked **exported** reach the shell scripts. Make does not
put makefile variables into a recipe's environment on its own, so the two
script-driven versions (`TETRAGON_VERSION`, `KUBEVIRT_VERSION`) are explicitly
`export`ed; without that, `make tetragon TETRAGON_VERSION=…` was silently
ignored and the script's own default won.

### `$(call tf,<dir>,<command>)` — Terraform in a container

```bash
docker run --rm \
  -u "$(id -u):$(id -g)" \          # your uid, so the tree doesn't end up root-owned
  -e HOME=/tmp \                    # the image has no home for a non-root user
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \   # MinIO state backend
  -e TF_VAR_pm_user=... -e TF_VAR_pm_password=... \         # Proxmox login
  -v "$PWD/<dir>:/terraform" \
  -v "$HOME/.kube:/tmp/.kube" \     # so the kube providers can reach the cluster
  -w /terraform --entrypoint sh renatofenrir/terraform:v7 -c '<command>'
```

Every `<command>` starts with `terraform init -backend-config=access_key=… -backend-config=secret_key=…`.

### `$(call kubespray,<playbook>)` — Kubespray in a container

```bash
docker run --rm \
  -v "$PWD/inventory/inventory.ini:/kubespray/inventory/inventory.ini:ro" \
  -v "$PWD/inventory/group-vars:/kubespray/inventory/group_vars:ro" \
  --mount "type=bind,source=$SSH_KEY,dst=/root/.ssh/id_rsa,readonly" \
  quay.io/kubespray/kubespray:v2.31.0 \
  ansible-playbook -i inventory/inventory.ini \
    -e ansible_user=ubuntu -e ansible_become=yes \
    -e host_key_checking=false -e kube_owner=root \
    --private-key /root/.ssh/id_rsa <playbook>
```

### `$(ON_MASTER) "<shell command>"` — run something on the control plane

```bash
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible -i inventory/inventory.ini \
  kube_control_plane -m shell -e "ansible_user=ubuntu ansible_become=yes" -a "<shell command>"
```

Runs as **root on `10.1.1.40`** over SSH. Used for `cilium`, `untaint`, `status`, `preflight`.

### Two different ways of reaching the cluster

| Mechanism | Used by | Which config |
|---|---|---|
| Your local `kubectl` | `lab`, `detect`, `mitigate`, `events`, the `*-clean` targets… | **whatever `KUBECONFIG` points at** — no `--context` is passed, so export it first |
| `ON_MASTER` (ansible + ssh) | `cilium`, `untaint`, `status`, `preflight` | the master's own root kubeconfig |
| Terraform providers | `crds`, `components`, `destroy-components` | **always `~/.kube/bsides-lab.conf`**, via `-var=kube_config_path=/tmp/.kube/bsides-lab.conf` |

⚠️ The plain `kubectl` targets have no safety net. Point `KUBECONFIG` at the
lab before running them:
`export KUBECONFIG=$HOME/.kube/bsides-lab.conf`

---

## Build (Phase 1)

### `make up`
Runs, in order: `vms` → `cluster` (→ `deps`) → `untaint` → `kubeconfig` → `crds` → `cilium` → `lb` → `components`. ~35–45 min.

### `make plan`
`terraform init && terraform plan` in `vms/`. Read-only. Expect `Plan: 2 to add`.
Needs `MINIO_ACCESS_TOKEN`, `MINIO_SECRET_KEY`, `TF_VAR_pm_user`, `TF_VAR_pm_password`.

### `make vms`
1. `terraform apply -auto-approve` in `vms/` — clones both VMs from template `template_vm_id`.
2. `ansible … -m wait_for_connection -a "timeout=300 sleep=5 delay=10"` on all hosts.
3. `ansible … -m shell -a "cloud-init status --wait"` on all hosts.

### `make deps`
`ansible-playbook -l kube_control_plane --user=ubuntu -e ansible_python_interpreter=/usr/bin/python3 install-master-deps.yml` — puts helm, the Cilium CLI, hubble, tetra and virtctl on the master. Pulled in automatically by `cluster`.

### `make cluster`
Depends on `deps`, then:
1. Kubespray `cluster.yml` in a container (20–30 min).
2. `ON_MASTER "mkdir -p /home/ubuntu/.kube && cp /etc/kubernetes/admin.conf … && chown -R ubuntu:ubuntu …"`.

Nodes read `NotReady` afterwards: there is no CNI yet. Expected.

### `make scale`
Kubespray `scale.yml` (not `cluster.yml`), then `ON_MASTER "kubectl get nodes -o wide"`. For joining a node you already added to `vms/variables.tf` and the inventory.

### `make untaint`
`ON_MASTER "kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true"`. Without it the control plane can't run workloads and the victim pod stays `Pending`.

### `make kubeconfig`
1. `ssh ubuntu@10.1.1.40 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/bsides-lab.conf`, then `chmod 600`.
2. `sed` the server to `https://10.1.1.40:6443` (the ClusterIP is unreachable until Cilium programs it).
3. `kubectl config rename-context kubernetes-admin@cluster.local bsides-krk-demo` — **required**, because prod uses the same default context name.

### `make crds`
`terraform apply -auto-approve -target=module.gateway_api_crds` in `components/`. Gateway API v1.5.1 CRDs only, before Cilium.

### `make cilium`
`ON_MASTER "cilium install --version 1.18.1 --set …"` with the lab's eleven flags (`cluster.name=default`, `ipam.mode=kubernetes`, `kubeProxyReplacement=true`, `l2announcements.enabled=true`, Hubble relay + UI, `socketLB.hostNamespaceOnly=true`, `k8sServiceHost/Port`, `k8sClientRateLimit`), then `ON_MASTER "cilium status --wait"`.

Not idempotent: on an existing install `cilium install` fails with "cannot re-use a name that is still in use". The CI job handles that by upgrading instead; from a laptop, use `cilium upgrade --reset-values …` with the same flags.

### `make lb`
Runs `./scripts/25-cilium-lb-ipam.sh`: applies `CiliumLoadBalancerIPPool bsides-lab-pool` (`10.1.1.240–249`) and `CiliumL2AnnouncementPolicy bsides-lab-l2`, then lists both. Idempotent.

### `make components` / `make components-plan`
`terraform apply -auto-approve` (or `plan`) in `components/`: metrics-server, local-path, CoreDNS/NodeLocalDNS config, and the Gateway API CRDs if `crds` didn't already apply them. Needs Cilium healthy first, or the Helm releases time out after 5 minutes.

---

## Phase 2 — the container demo

### `make lab`
Depends on `tetragon`, then:
1. `kubectl apply -f phase2-container-lab/attack/netshoot.yaml` — namespace, attacker, victim, victim Service.
2. `kubectl -n tetragon-demo wait --for=condition=ready pod --all --timeout=180s`.

**~7 s (measured)** when Tetragon is already installed.

### `make tetragon`
Runs `./scripts/30-install-tetragon.sh`:
1. `helm repo add cilium https://helm.cilium.io && helm repo update`
2. `helm upgrade --install tetragon cilium/tetragon --version 1.4.0 -n kube-system --set tetragon.enableProcessCred=true --set tetragon.enableProcessNs=true --set tetragon.extraArgs.disable-kprobe-multi=true`
3. `kubectl -n kube-system rollout status ds/tetragon --timeout=180s`
4. Fails the build if the agent log contains `adding tracing policy failed`.
5. Installs the local `tetra` CLI if missing — skip with `SKIP_TETRA_CLI=1` (it needs `sudo`).

`disable-kprobe-multi` is **required** on this kernel; without it every policy loads into nothing. See `LAB_GUIDE.md` §2.4.

### `make detect`
`kubectl apply -f phase2-container-lab/policies/00-monitor-outside-cluster-cidr.yaml`. One TracingPolicy, observe-only.

### `make mitigate`
```bash
kubectl apply -f phase2-container-lab/policies/10-kill-network-recon-binaries.yaml
kubectl apply -f phase2-container-lab/policies/20-kill-tcpdump.yaml
```
Instant to apply; allow ~15 s for the hooks to attach on both nodes. **Cluster-wide** — `curl` dies in every pod while this is applied.

### `make unmitigate`
```bash
kubectl delete tracingpolicy kill-network-recon-binaries --ignore-not-found
kubectl delete tracingpolicy kill-tcpdump --ignore-not-found
```
Leaves the detection policy in place. Does **not** touch the namespaced variant (`11`), which is a different kind:
`kubectl delete tracingpolicynamespaced kill-network-recon-binaries -n tetragon-demo`

---

## The rehearsal loop

At a glance:

| Target | Removes | Keeps |
|---|---|---|
| `make lab-clean` | all policies, attacker, victim, namespace | Tetragon, cluster |
| `make lab-reset` | the above, then redeploys | Tetragon, cluster |
| `make lab-purge` | the above plus Tetragon | cluster |
| `make kubevirt-clean` | Phase 3 namespace and policies | KubeVirt |
| `make kubevirt-reset` | the above, then redeploys | KubeVirt |

⚠️ `make reset` is **not** part of this group: it wipes the whole Kubernetes
install via Kubespray. See [Teardown](#teardown).

### `make lab-clean`
```bash
kubectl delete tracingpolicy kill-network-recon-binaries kill-tcpdump \
  monitor-network-activity-outside-cluster-cidr-range --ignore-not-found
kubectl delete tracingpolicynamespaced kill-network-recon-binaries -n tetragon-demo --ignore-not-found
kubectl delete -f phase2-container-lab/attack/netshoot.yaml --ignore-not-found
kubectl wait --for=delete namespace/tetragon-demo --timeout=180s
```
**~43 s (measured)**, nearly all of it the namespace terminating. The `wait` matters: without it a following `make lab` races a namespace still going away and the pods never schedule. Keeps Tetragon.

### `make lab-reset`
`lab-clean` then `lab`. **~49 s (measured)** per cycle. The repeatable rehearsal loop:
```bash
SKIP_TETRA_CLI=1 make lab-reset && make detect    # attacks… → make mitigate
```

### `make lab-purge`
`lab-clean`, then `helm -n kube-system uninstall tetragon`. `make lab` puts it back.

### `make kubevirt-clean`
`kubectl delete namespace kubevirt-demo --ignore-not-found`, then waits up to 300 s for it to go. Removes the VM, Service, Gateway, client and both CiliumNetworkPolicies. KubeVirt itself stays installed.

### `make kubevirt-reset`
`kubevirt-clean` then `kubevirt`. The Phase 3 rehearsal loop, parallel to `lab-reset`:
```bash
make kubevirt-reset && make kubevirt-ready && make kubevirt-test
```

---

## Phase 3 🚧

### `make kubevirt`
Requires `VM_CONSOLE_PASSWORD` exported — refuses to run otherwise. Depends on
`unmitigate` (Phase 2's kill policy would SIGKILL Phase 3's curls), then:
1. `./scripts/40-install-kubevirt.sh` at `KUBEVIRT_VERSION` (pinned `v1.9.0`, matching the `virtctl` on the master) — operator + CR, nested-virt check, waits up to 15 min for `Available`, installs `virtctl`.
2. Renders `cloud-init/nginx-vm-user-data.yaml`'s `__VM_CONSOLE_PASSWORD__`
   placeholder with `sed` into a temp file, builds the `nginx-vm-cloudinit`
   Secret from *that* (not the repo file directly), and deletes the temp file.
   The committed cloud-init never contains a real password.
3. `kubectl apply -f` each of `10-nginx-vm.yaml`, `20-service.yaml`, `30-gateway-httproute.yaml`, `40-tmp-client.yaml`.

The VM then needs ~4 min for cloud-init. The L4/L7 policies are applied by hand during the demo. See `phase3-kubevirt-lab/README.md` — the Gateway half is currently inert because Cilium has Gateway API off.

### `make kubevirt-ready`
Blocks instead of guessing: `kubectl wait` for `tmp-client`, then polls
`wget -qO- http://nginx/guest-ready` from inside it every 5 s (up to 5 min)
until cloud-init writes the marker file. Replaces eyeballing the boot on the
console. Exits 1 with a hint to check `virtctl console` if it times out.

### `make kubevirt-test`
One-shot check of both access paths, so the empty Gateway address reads as an
expected result instead of a dead end mid-demo:
```bash
kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/details   # works
kubectl -n kubevirt-demo get gateway nginx-gw                                # stays Pending, no address
```

---

## Observability and checks

### `make events`
Resolves the attacker's node, finds the Tetragon pod on **that** node, then:
```bash
kubectl -n kube-system exec <pod> -c tetragon -- tetra getevents -o compact --pod attacker
```
Events are per node, so streaming from the wrong pod shows nothing. Fails with a clear message if the attacker pod is absent.

### `make events-all`
`kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact` — one arbitrary node, unfiltered. Noisy; the old behaviour of `make events`.

### `make events-vm`
Phase 3 beat 3's version of `make events`: resolves `nginx-vm`'s node from `kubectl -n kubevirt-demo get vmi nginx-vm -o jsonpath='{.status.nodeName}'`, finds the Tetragon pod on that node, then streams it unfiltered (no `--pod` filter — the guest's processes never show up as a Kubernetes pod for Tetragon to filter by; that absence is the point of beat 3). Fails with a clear message if `nginx-vm` is absent.

### `make status`
`ON_MASTER "cilium status --brief"`, then `kubectl get nodes -o wide`, `kubectl get tracingpolicies`, `kubectl -n kubevirt-demo get vmi`. All best-effort.

### `make preflight`
The night-before checks:
1. `ON_MASTER "cilium status --wait"`
2. `kubectl get nodes`
3. `ansible all -m shell -a 'grep -wcE "raw_sendmsg|packet_sendmsg" /proc/kallsyms'` — the static symbols the kill policy needs.
4. Greps the Tetragon log for `adding tracing policy failed` — the only place a silently inert policy shows up.
5. `ansible all -m shell -a 'grep -cE "vmx|svm" /proc/cpuinfo'` — nested virt for Phase 3.

---

## Teardown

### `make down`
Prompts for the literal word `destroy`, then `make destroy-components` (best-effort, `-` prefix) and `make destroy-vms`. Prod is in a different repo with a different state key and isn't touched.

### `make destroy-components`
`terraform destroy -auto-approve` in `components/`. Add-ons only; the cluster stays.

### `make reset`
**DESTRUCTIVE.** Kubespray `reset.yml` with `-e reset_confirmation=yes` — wipes the Kubernetes install and leaves the VMs. **Not** the rehearsal loop; that's `lab-reset`.

### `make destroy-vms`
`terraform destroy -auto-approve` in `vms/`. Deletes both VMs, which takes the cluster with them.

### `make clean`
Local only: `rm -rf vms/.terraform components/.terraform` and `rm -f ~/.kube/bsides-lab.conf`. Touches nothing remote.

---

## What each target needs

| Target group | Needs |
|---|---|
| `plan`, `vms`, `destroy-vms` | MinIO creds, `TF_VAR_pm_user`/`TF_VAR_pm_password`, Proxmox reachable |
| `crds`, `components*`, `destroy-components` | MinIO creds **and** `~/.kube/bsides-lab.conf` |
| `cluster`, `scale`, `reset`, `deps` | docker, ansible, SSH to both nodes as `ubuntu` |
| `cilium`, `untaint`, `status`, `preflight` | ansible + SSH to the master |
| everything Phase 2 / Phase 3 | `KUBECONFIG` pointing at the lab, and a healthy cluster |
| `kubevirt`, `kubevirt-reset` | the above, **and** `VM_CONSOLE_PASSWORD` exported |
