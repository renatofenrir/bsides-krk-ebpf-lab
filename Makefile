# ===========================================================================
# BSides Kraków eBPF lab
#
# Build it, run the talk on it, destroy it. `make help` lists everything.
#
# Everything runs in containers -- the same Kubespray and Terraform images the
# prod pipeline uses -- so the only hard dependencies on the laptop are docker,
# ansible and ssh.
#
# Every target below echoes "[INFO] Running: <command>" immediately before it
# runs that command, and every such command line is prefixed `@` so Make's own
# default echo doesn't duplicate it. This is deliberate: on stage, the audience
# only sees `make <target>` typed at the prompt -- without this, what actually
# executes (which kubectl/terraform/ansible call, against what) is invisible.
# The two `tf`/`kubespray` container macros embed real secrets (MinIO/Proxmox
# credentials) in their docker invocation, so their targets print a REDACTED
# description instead of the literal command -- never echo those macros raw.
# ===========================================================================

SHELL             := /bin/bash
.DEFAULT_GOAL     := help

KUBESPRAY_IMG     ?= quay.io/kubespray/kubespray:v2.31.0
TF_IMG            ?= renatofenrir/terraform:v7
SSH_KEY           ?= $(HOME)/.ssh/id_rsa
MASTER_IP         ?= 10.1.1.40
CONTEXT           ?= bsides-krk-demo
CILIUM_VERSION    ?= 1.18.1
TETRAGON_VERSION  ?= 1.4.0
# Pinned, not "whatever stable.txt says today": virtctl on the master is
# installed at this version by install-master-deps.yml, and a floating KubeVirt
# would drift away from it between rehearsal and talk.
KUBEVIRT_VERSION  ?= v1.9.0

# Make does NOT put makefile variables into a recipe's environment unless they
# are exported, so without this `make tetragon TETRAGON_VERSION=x` would be
# silently ignored by the script.
export TETRAGON_VERSION
export KUBEVIRT_VERSION

# MinIO-as-S3 backend credentials, same as prod.
AWS_ACCESS_KEY_ID     ?= $(MINIO_ACCESS_TOKEN)
AWS_SECRET_ACCESS_KEY ?= $(MINIO_SECRET_KEY)

TF_INIT_ARGS := -backend-config=access_key=$(AWS_ACCESS_KEY_ID) \
                -backend-config=secret_key=$(AWS_SECRET_ACCESS_KEY)

# Run terraform as the invoking user so the working tree does not end up
# root-owned. Prod's CI chowns afterwards instead; locally this is tidier.
#
# NEVER echo this macro's expansion: it inlines AWS_SECRET_ACCESS_KEY and
# TF_VAR_pm_password in plain text. Targets that use it print a redacted
# "[INFO] Running:" description by hand instead.
define tf
	docker run --rm \
	  -u "$$(id -u):$$(id -g)" \
	  -e HOME=/tmp \
	  -e AWS_ACCESS_KEY_ID="$(AWS_ACCESS_KEY_ID)" \
	  -e AWS_SECRET_ACCESS_KEY="$(AWS_SECRET_ACCESS_KEY)" \
	  -e TF_VAR_pm_user="$(TF_VAR_pm_user)" \
	  -e TF_VAR_pm_password="$(TF_VAR_pm_password)" \
	  -v "$(PWD)/$(1):/terraform" \
	  -v "$(HOME)/.kube:/tmp/.kube" \
	  -w /terraform \
	  --entrypoint sh $(TF_IMG) -c '$(2)'
endef

# Kubespray, with inventory and group_vars mounted read-only. No secret VALUES
# are inlined here (SSH_KEY is a file path, mounted rather than embedded), so
# unlike `tf` this one is safe to echo literally.
define kubespray
	docker run --rm \
	  -v "$(PWD)/inventory/inventory.ini:/kubespray/inventory/inventory.ini:ro" \
	  -v "$(PWD)/inventory/group-vars:/kubespray/inventory/group_vars:ro" \
	  --mount "type=bind,source=$(SSH_KEY),dst=/root/.ssh/id_rsa,readonly" \
	  $(KUBESPRAY_IMG) \
	  ansible-playbook -i inventory/inventory.ini \
	    -e ansible_user=ubuntu -e ansible_become=yes \
	    -e host_key_checking=false -e kube_owner=root \
	    --private-key /root/.ssh/id_rsa $(1)
endef

ANSIBLE := ANSIBLE_CONFIG=$(PWD)/ansible.cfg ansible
ANSIBLE_PLAYBOOK := ANSIBLE_CONFIG=$(PWD)/ansible.cfg ansible-playbook
ON_MASTER := $(ANSIBLE) -i inventory/inventory.ini kube_control_plane -m shell -e "ansible_user=ubuntu ansible_become=yes" -a

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  BSides Kraków eBPF lab"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Typical run:   make up   →  make lab   →  make down"
	@echo ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

.PHONY: up
up: vms cluster untaint kubeconfig crds cilium lb components ## Full build: VMs → cluster → Cilium → add-ons
	@echo ""
	@echo "Cluster is up. Next: make lab"

.PHONY: plan
plan: ## terraform plan for the VMs (read-only, safe)
	@echo "[INFO] Running: terraform plan (vms/, containerized via $(TF_IMG))"
	@$(call tf,vms,terraform init $(TF_INIT_ARGS) && terraform plan)

.PHONY: vms
vms: ## Create the two Proxmox VMs
	@echo "[INFO] Running: terraform apply -auto-approve (vms/, containerized via $(TF_IMG))"
	@$(call tf,vms,terraform init $(TF_INIT_ARGS) && terraform apply -auto-approve)
	@echo "[INFO] Running: ansible wait_for_connection (all hosts, up to 300s)"
	@$(ANSIBLE) -i inventory/inventory.ini all -m wait_for_connection \
	  -a "timeout=300 sleep=5 delay=10" -e "ansible_user=ubuntu ansible_become=yes"
	@echo "[INFO] Running: ansible shell 'cloud-init status --wait' (all hosts)"
	@$(ANSIBLE) -i inventory/inventory.ini all -m shell -a "cloud-init status --wait" \
	  -e "ansible_user=ubuntu ansible_become=yes"

.PHONY: deps
deps: ## Install helm/cilium/hubble/tetra/virtctl on the control plane
	@echo "[INFO] Running: ansible-playbook install-master-deps.yml (kube_control_plane)"
	@$(ANSIBLE_PLAYBOOK) -i inventory/inventory.ini -l kube_control_plane \
	  --user=ubuntu -e 'ansible_python_interpreter=/usr/bin/python3' install-master-deps.yml

.PHONY: cluster
cluster: deps ## Bootstrap Kubernetes with Kubespray (no CNI, no kube-proxy)
	@echo "[INFO] Running: Kubespray cluster.yml (containerized via $(KUBESPRAY_IMG); 20-30 min)"
	@$(call kubespray,cluster.yml)
	@echo "[INFO] Running: copy /etc/kubernetes/admin.conf to ubuntu's kubeconfig (control plane)"
	@$(ON_MASTER) "mkdir -p /home/ubuntu/.kube && cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && chown -R ubuntu:ubuntu /home/ubuntu/.kube"
	@echo ""
	@echo "[INFO] Nodes will read NotReady until Cilium is installed. Expected."

.PHONY: scale
scale: ## Join a newly-added node (Kubespray scale.yml, not a full re-run)
	@# Adding a third node: append its IP to worker_ips in vms/variables.tf,
	@# add it to inventory/inventory.ini, `make vms`, then this.
	@#
	@# scale.yml rather than cluster.yml on purpose -- cluster.yml re-runs every
	@# role against every node, including the control plane, which on a live
	@# demo cluster is a long way to go for one extra worker.
	@echo "[INFO] Running: Kubespray scale.yml (containerized via $(KUBESPRAY_IMG))"
	@$(call kubespray,scale.yml)
	@echo "[INFO] Running: kubectl get nodes -o wide (via control plane)"
	@$(ON_MASTER) "kubectl get nodes -o wide"

.PHONY: untaint
untaint: ## Make the control plane schedulable (two-node cluster needs this)
	@echo "[INFO] Running: kubectl taint nodes --all node-role.kubernetes.io/control-plane- (via control plane)"
	@$(ON_MASTER) "kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true"

.PHONY: kubeconfig
kubeconfig: ## Pull the kubeconfig to the laptop under its own context
	@mkdir -p $(HOME)/.kube
	@echo "[INFO] Running: ssh ubuntu@$(MASTER_IP) sudo cat /etc/kubernetes/admin.conf"
	@ssh -o StrictHostKeyChecking=no ubuntu@$(MASTER_IP) \
	  "sudo cat /etc/kubernetes/admin.conf" > $(HOME)/.kube/bsides-lab.conf
	@chmod 600 $(HOME)/.kube/bsides-lab.conf
	@# Point at the node IP: with kube-proxy removed the ClusterIP is not
	@# reachable until Cilium programs it, and Cilium needs the API first.
	@sed -i 's#server: https://127.0.0.1:6443#server: https://$(MASTER_IP):6443#' $(HOME)/.kube/bsides-lab.conf
	@KUBECONFIG=$(HOME)/.kube/bsides-lab.conf kubectl config rename-context \
	  kubernetes-admin@cluster.local $(CONTEXT) 2>/dev/null || true
	@echo ""
	@echo "  export KUBECONFIG=$(HOME)/.kube/bsides-lab.conf"

.PHONY: crds
crds: ## Gateway API CRDs (same v1.5.1 as prod; Cilium has Gateway API off)
	@# Keeps the lab's CRDs identical to prod's. Cilium does not consume them:
	@# with gatewayAPI.enabled=true, Cilium 1.18.1's operator crash-loops on
	@# v1.5.1's TLSRoute, so the flag is off here just as in prod.
	@#
	@# Same shape as prod's bootstrap-crds stage: one targeted apply against the
	@# components state, before the thing that depends on it exists. The rest of
	@# the stack (metrics-server, local-path) would just sit Pending this early,
	@# because there is still no CNI -- so it waits for `make components`.
	@echo "[INFO] Running: terraform apply -target=module.gateway_api_crds (components/, containerized via $(TF_IMG))"
	@$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform apply -auto-approve -target=module.gateway_api_crds -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

.PHONY: cilium
cilium: ## Install Cilium with the lab's flag set, from the control plane
	@echo "[INFO] Running: cilium install --version $(CILIUM_VERSION) [lab flag set] (via control plane)"
	@$(ON_MASTER) "cilium install --version $(CILIUM_VERSION) \
	  --set cluster.name=default \
	  --set ipam.mode=kubernetes \
	  --set kubeProxyReplacement=true \
	  --set l2announcements.enabled=true \
	  --set hubble.relay.enabled=true \
	  --set hubble.ui.enabled=true \
	  --set socketLB.hostNamespaceOnly=true \
	  --set k8sServiceHost=$(MASTER_IP) \
	  --set k8sServicePort=6443 \
	  --set k8sClientRateLimit.qps=50 \
	  --set k8sClientRateLimit.burst=200"
	@echo "[INFO] Running: cilium status --wait (via control plane)"
	@$(ON_MASTER) "cilium status --wait"

.PHONY: lb
lb: ## Apply the LoadBalancer IP pool and L2 announcement policy
	@echo "[INFO] Running: scripts/25-cilium-lb-ipam.sh"
	@./scripts/25-cilium-lb-ipam.sh

.PHONY: components
components: ## Apply the add-on stack (Gateway API CRDs, metrics-server, local-path, CoreDNS)
	@echo "[INFO] Running: terraform apply (components/, containerized via $(TF_IMG))"
	@$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform apply -auto-approve -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

.PHONY: components-plan
components-plan: ## terraform plan for the add-on stack
	@echo "[INFO] Running: terraform plan (components/, containerized via $(TF_IMG))"
	@$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform plan -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

# ---------------------------------------------------------------------------
# The lab itself
# ---------------------------------------------------------------------------

.PHONY: lab
lab: tetragon ## Deploy Phase 2: Tetragon + attacker + victim
	@echo "[INFO] Running: kubectl apply -f phase2-container-lab/attack/netshoot.yaml"
	@kubectl apply -f phase2-container-lab/attack/netshoot.yaml
	@echo "[INFO] Running: kubectl -n tetragon-demo wait --for=condition=ready pod --all --timeout=180s"
	@kubectl -n tetragon-demo wait --for=condition=ready pod --all --timeout=180s
	@echo ""
	@echo "Ready. Detection policy:  make detect"
	@echo "Then mitigation:          make mitigate"

.PHONY: tetragon
tetragon: ## Install Tetragon
	@echo "[INFO] Running: scripts/30-install-tetragon.sh"
	@./scripts/30-install-tetragon.sh

.PHONY: detect
detect: ## Phase 2.3 -- apply the detection TracingPolicy
	@echo "[INFO] Running: kubectl apply -f phase2-container-lab/policies/00-monitor-outside-cluster-cidr.yaml"
	@kubectl apply -f phase2-container-lab/policies/00-monitor-outside-cluster-cidr.yaml

.PHONY: mitigate
mitigate: ## Phase 2.4 -- apply the SIGKILL TracingPolicies
	@echo "[INFO] Running: kubectl apply -f phase2-container-lab/policies/10-kill-network-recon-binaries.yaml"
	@kubectl apply -f phase2-container-lab/policies/10-kill-network-recon-binaries.yaml
	@echo "[INFO] Running: kubectl apply -f phase2-container-lab/policies/20-kill-tcpdump.yaml"
	@kubectl apply -f phase2-container-lab/policies/20-kill-tcpdump.yaml

.PHONY: unmitigate
unmitigate: ## Drop the cluster-wide kill policies (REQUIRED before `make kubevirt`)
	@echo "[INFO] Running: kubectl delete tracingpolicy kill-network-recon-binaries"
	@kubectl delete tracingpolicy kill-network-recon-binaries --ignore-not-found
	@echo "[INFO] Running: kubectl delete tracingpolicy kill-tcpdump"
	@kubectl delete tracingpolicy kill-tcpdump --ignore-not-found

.PHONY: kubevirt
kubevirt: unmitigate ## Phase 3 (DRAFT) -- KubeVirt, the VM, Gateway and client
	@echo "[INFO] Running: scripts/40-install-kubevirt.sh (KubeVirt $(KUBEVIRT_VERSION))"
	@./scripts/40-install-kubevirt.sh
	@# The VM's cloud-config is ~4.5 KB and KubeVirt caps INLINE userData at
	@# 2048 bytes, so it ships as a Secret built from the file on disk. Edit
	@# cloud-init/nginx-vm-user-data.yaml, re-run this, and restart the VM.
	@echo "[INFO] Running: kubectl create namespace kubevirt-demo (apply)"
	@kubectl create namespace kubevirt-demo --dry-run=client -o yaml | kubectl apply -f -
	@echo "[INFO] Running: kubectl create secret nginx-vm-cloudinit (apply, from cloud-init/nginx-vm-user-data.yaml)"
	@kubectl -n kubevirt-demo create secret generic nginx-vm-cloudinit \
	  --from-file=userdata=phase3-kubevirt-lab/cloud-init/nginx-vm-user-data.yaml \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "[INFO] Running: kubectl apply -f phase3-kubevirt-lab/10-nginx-vm.yaml"
	@kubectl apply -f phase3-kubevirt-lab/10-nginx-vm.yaml
	@echo "[INFO] Running: kubectl apply -f phase3-kubevirt-lab/20-service.yaml"
	@kubectl apply -f phase3-kubevirt-lab/20-service.yaml
	@echo "[INFO] Running: kubectl apply -f phase3-kubevirt-lab/30-gateway-httproute.yaml"
	@kubectl apply -f phase3-kubevirt-lab/30-gateway-httproute.yaml
	@echo "[INFO] Running: kubectl apply -f phase3-kubevirt-lab/40-tmp-client.yaml"
	@kubectl apply -f phase3-kubevirt-lab/40-tmp-client.yaml
	@echo ""
	@echo "VM is booting -- cloud-init installs nginx, nmap, tcpdump and Tetragon."
	@echo "Measured 20-100s to ready; allow minutes on a cold image pull."
	@echo "Watch the boot:   virtctl console --timeout=5 nginx-vm -n kubevirt-demo   (Ctrl+] to detach)"
	@echo "Ready when:       make kubevirt-ready"

.PHONY: kubevirt-ready
kubevirt-ready: ## Block until tmp-client is up and the guest's cloud-init has finished
	@echo "[INFO] Running: kubectl -n kubevirt-demo wait --for=condition=ready pod/tmp-client --timeout=120s"
	@kubectl -n kubevirt-demo wait --for=condition=ready pod/tmp-client --timeout=120s
	@echo "[INFO] Running: kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/guest-ready (polling every 5s, up to 5min)"
	@for i in $$(seq 1 60); do \
	  if kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/guest-ready 2>/dev/null | grep -q ready; then \
	    echo "[INFO] Guest ready after ~$$((i * 5))s."; exit 0; \
	  fi; \
	  sleep 5; \
	done; \
	echo "[WARN] Not ready after 5 min -- check: virtctl console nginx-vm -n kubevirt-demo"; exit 1

.PHONY: kubevirt-test
kubevirt-test: ## Check both access paths: Service (works) and Gateway (stays Pending -- expected)
	@echo "[INFO] Running: kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/details"
	@kubectl -n kubevirt-demo exec tmp-client -- wget -qO- http://nginx/details \
	  || echo "  FAILED -- is the VM ready? (make kubevirt-ready)"
	@echo ""
	@echo "[INFO] Running: kubectl -n kubevirt-demo get gateway nginx-gw (Cilium has Gateway API off -- stays Pending)"
	@kubectl -n kubevirt-demo get gateway nginx-gw

# --- Rehearsal loop --------------------------------------------------------
#
# Phase 2 is meant to be run over and over until the outcome is boring. These
# targets remove it from the cluster and put it back, without touching
# Kubernetes itself. (`make reset` is a different, DESTRUCTIVE thing: it wipes
# the cluster via Kubespray.)

.PHONY: lab-clean
lab-clean: ## Remove Phase 2 from the cluster (policies + attacker/victim). Keeps Tetragon
	@echo "[INFO] Running: kubectl delete tracingpolicy kill-network-recon-binaries kill-tcpdump monitor-network-activity-outside-cluster-cidr-range"
	-@kubectl delete tracingpolicy kill-network-recon-binaries kill-tcpdump \
	  monitor-network-activity-outside-cluster-cidr-range --ignore-not-found
	@echo "[INFO] Running: kubectl delete tracingpolicynamespaced kill-network-recon-binaries -n tetragon-demo"
	-@kubectl delete tracingpolicynamespaced kill-network-recon-binaries \
	  -n tetragon-demo --ignore-not-found 2>/dev/null
	@echo "[INFO] Running: kubectl delete -f phase2-container-lab/attack/netshoot.yaml"
	-@kubectl delete -f phase2-container-lab/attack/netshoot.yaml --ignore-not-found
	@# The namespace must be fully gone before `make lab` recreates it, or the
	@# apply races the terminating namespace and the pods never schedule.
	@echo "[INFO] Running: kubectl wait --for=delete namespace/tetragon-demo --timeout=180s"
	@kubectl wait --for=delete namespace/tetragon-demo --timeout=180s 2>/dev/null || true
	@echo "[INFO] Phase 2 removed. Tetragon is still installed."

.PHONY: lab-reset
lab-reset: lab-clean lab ## Tear Phase 2 down and bring it back (repeatable rehearsal loop)
	@echo ""
	@echo "Fresh Phase 2. Next: make detect  →  attacks  →  make mitigate"

.PHONY: lab-purge
lab-purge: lab-clean ## Also uninstall Tetragon itself (full Phase 2 removal)
	@echo "[INFO] Running: helm -n kube-system uninstall tetragon"
	-@helm -n kube-system uninstall tetragon
	@echo "[INFO] Tetragon uninstalled. 'make lab' reinstalls it."

.PHONY: kubevirt-clean
kubevirt-clean: ## Remove Phase 3 objects (VM, Service, Gateway, client, policies)
	@echo "[INFO] Running: kubectl delete namespace kubevirt-demo"
	-@kubectl delete namespace kubevirt-demo --ignore-not-found
	@echo "[INFO] Running: kubectl wait --for=delete namespace/kubevirt-demo --timeout=300s"
	@kubectl wait --for=delete namespace/kubevirt-demo --timeout=300s 2>/dev/null || true
	@echo "[INFO] Phase 3 removed. KubeVirt itself is still installed."

.PHONY: kubevirt-reset
kubevirt-reset: kubevirt-clean kubevirt ## Tear Phase 3 down and bring it back (repeatable rehearsal loop)
	@echo ""
	@echo "Fresh Phase 3. Next: make kubevirt-ready  →  make kubevirt-test"

.PHONY: events
events: ## Stream Tetragon events from the attacker's node (the 'terminal 2')
	@# Tetragon events are PER NODE. `kubectl exec ds/tetragon` picks one pod --
	@# on this cluster the control plane's -- while the attacker runs on the
	@# worker, so the attacks never show up and the stream fills with unrelated
	@# kube-system activity. Pick the pod on the attacker's node instead.
	@echo "[INFO] Running: kubectl -n tetragon-demo get pod attacker -o jsonpath='{.spec.nodeName}'"
	@node=$$(kubectl -n tetragon-demo get pod attacker -o jsonpath='{.spec.nodeName}' 2>/dev/null); \
	if [ -z "$$node" ]; then echo "attacker pod not found -- run 'make lab' first"; exit 1; fi; \
	echo "[INFO] Running: kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon --field-selector spec.nodeName=$$node"; \
	pod=$$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
	        --field-selector spec.nodeName=$$node -o jsonpath='{.items[0].metadata.name}'); \
	echo "[INFO] Running: kubectl -n kube-system exec $$pod -c tetragon -- tetra getevents -o compact --pod attacker"; \
	kubectl -n kube-system exec $$pod -c tetragon -- tetra getevents -o compact --pod attacker

.PHONY: events-all
events-all: ## Stream Tetragon events from every node, unfiltered (noisy)
	@echo "[INFO] Running: kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact"
	@kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact

.PHONY: events-vm
events-vm: ## Phase 3 beat 3 -- stream Tetragon events from nginx-vm's own node
	@# Same reasoning as `events`: Tetragon is per node, and the host agent that
	@# matters here is the one on whichever node the VM landed on -- not
	@# whatever `ds/tetragon` happens to pick.
	@echo "[INFO] Running: kubectl -n kubevirt-demo get vmi nginx-vm -o jsonpath='{.status.nodeName}'"
	@node=$$(kubectl -n kubevirt-demo get vmi nginx-vm -o jsonpath='{.status.nodeName}' 2>/dev/null); \
	if [ -z "$$node" ]; then echo "nginx-vm not found -- run 'make kubevirt' first"; exit 1; fi; \
	echo "[INFO] Running: kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon --field-selector spec.nodeName=$$node"; \
	pod=$$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
	        --field-selector spec.nodeName=$$node -o jsonpath='{.items[0].metadata.name}'); \
	echo "[INFO] Running: kubectl -n kube-system exec $$pod -c tetragon -- tetra getevents -o compact"; \
	kubectl -n kube-system exec $$pod -c tetragon -- tetra getevents -o compact

.PHONY: status
status: ## Where is everything?
	@echo "[INFO] Running: cilium status --brief (via control plane)"
	@$(ON_MASTER) "cilium status --brief" || true
	@echo "[INFO] Running: kubectl get nodes -o wide"
	@kubectl get nodes -o wide 2>/dev/null || true
	@echo "[INFO] Running: kubectl get tracingpolicies"
	@kubectl get tracingpolicies 2>/dev/null || true
	@echo "[INFO] Running: kubectl -n kubevirt-demo get vmi"
	@kubectl -n kubevirt-demo get vmi 2>/dev/null || true

.PHONY: preflight
preflight: ## Run the night-before checks
	@echo "── Cilium ─────────────────────────────"
	@echo "[INFO] Running: cilium status --wait (via control plane)"
	@$(ON_MASTER) "cilium status --wait"
	@echo "── Nodes ──────────────────────────────"
	@echo "[INFO] Running: kubectl get nodes"
	@kubectl get nodes
	@echo "── Static kprobe symbols ──────────────"
	@echo "[INFO] Running: ansible shell 'grep -wcE raw_sendmsg|packet_sendmsg /proc/kallsyms' (all hosts)"
	@$(ANSIBLE) -i inventory/inventory.ini all -m shell \
	  -e "ansible_user=ubuntu ansible_become=yes" \
	  -a 'grep -wcE "raw_sendmsg|packet_sendmsg" /proc/kallsyms'
	@echo "── TracingPolicies actually loaded? ───"
	@# The CRD has no status field: a policy can be "applied" and inert. The
	@# agent log is the only place this shows up. Seen 2026-09-20 with
	@# kprobe-multi on kernel 7.0.0-31-generic.
	@echo "[INFO] Running: kubectl -n kube-system logs ds/tetragon -c tetragon --tail=300 | grep 'adding tracing policy failed'"
	@if kubectl -n kube-system logs ds/tetragon -c tetragon --tail=300 2>/dev/null \
	     | grep -q "adding tracing policy failed"; then \
	  echo "  FAIL: a TracingPolicy did not load -- see:"; \
	  echo "    kubectl -n kube-system logs ds/tetragon -c tetragon | grep 'adding tracing policy failed'"; \
	else echo "  ok (no load failures in the recent agent log)"; fi
	@echo "── Nested virt (Phase 3) ──────────────"
	@echo "[INFO] Running: ansible shell 'grep -cE vmx|svm /proc/cpuinfo' (all hosts)"
	@$(ANSIBLE) -i inventory/inventory.ini all -m shell \
	  -e "ansible_user=ubuntu ansible_become=yes" \
	  -a 'grep -cE "vmx|svm" /proc/cpuinfo'

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

.PHONY: down
down: ## Destroy everything -- add-ons, cluster, VMs (prompts once)
	@echo ""
	@echo "  This destroys the lab cluster and both VMs (10.1.1.40, .41)."
	@echo "  Prod (bifrost-prod-v4, 10.1.1.50-93) is in a different repo with a"
	@echo "  different state key and is NOT touched."
	@echo ""
	@read -p "  Type 'destroy' to continue: " c && [ "$$c" = "destroy" ]
	@# Best-effort. Tearing down helm releases on a cluster that is about to
	@# stop existing is optional, and it hangs if the API is already gone --
	@# hence the `|| true`. The leftover state reconciles on the next apply:
	@# refresh finds the releases missing and plans to recreate them.
	@echo "[INFO] Running: make destroy-components"
	-@$(MAKE) destroy-components
	@echo "[INFO] Running: make destroy-vms"
	@$(MAKE) destroy-vms
	@echo "Lab destroyed."

.PHONY: destroy-components
destroy-components: ## terraform destroy the add-on stack only
	@echo "[INFO] Running: terraform destroy -auto-approve (components/, containerized via $(TF_IMG))"
	@$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform destroy -auto-approve -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

.PHONY: reset
reset: ## DESTRUCTIVE: Kubespray reset.yml, wipes Kubernetes (for Phase 2 use lab-reset)
	@echo "[INFO] Running: Kubespray reset.yml -e reset_confirmation=yes (containerized via $(KUBESPRAY_IMG))"
	@$(call kubespray,--extra-vars reset_confirmation=yes reset.yml)

.PHONY: destroy-vms
destroy-vms: ## terraform destroy the two VMs
	@echo "[INFO] Running: terraform destroy -auto-approve (vms/, containerized via $(TF_IMG))"
	@$(call tf,vms,terraform init $(TF_INIT_ARGS) && terraform destroy -auto-approve)

.PHONY: clean
clean: ## Remove local terraform caches and the lab kubeconfig
	@echo "[INFO] Running: rm -rf vms/.terraform components/.terraform"
	@rm -rf vms/.terraform components/.terraform
	@echo "[INFO] Running: rm -f $(HOME)/.kube/bsides-lab.conf"
	@rm -f $(HOME)/.kube/bsides-lab.conf
