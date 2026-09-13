# ===========================================================================
# BSides Kraków eBPF lab
#
# Build it, run the talk on it, destroy it. `make help` lists everything.
#
# Everything runs in containers -- the same Kubespray and Terraform images the
# prod pipeline uses -- so the only hard dependencies on the laptop are docker,
# ansible and ssh.
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

# MinIO-as-S3 backend credentials, same as prod.
AWS_ACCESS_KEY_ID     ?= $(MINIO_ACCESS_TOKEN)
AWS_SECRET_ACCESS_KEY ?= $(MINIO_SECRET_KEY)

TF_INIT_ARGS := -backend-config=access_key=$(AWS_ACCESS_KEY_ID) \
                -backend-config=secret_key=$(AWS_SECRET_ACCESS_KEY)

# Run terraform as the invoking user so the working tree does not end up
# root-owned. Prod's CI chowns afterwards instead; locally this is tidier.
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

# Kubespray, with inventory and group_vars mounted read-only.
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
	$(call tf,vms,terraform init $(TF_INIT_ARGS) && terraform plan)

.PHONY: vms
vms: ## Create the two Proxmox VMs
	$(call tf,vms,terraform init $(TF_INIT_ARGS) && terraform apply -auto-approve)
	@echo "[INFO] Waiting for SSH on both nodes..."
	$(ANSIBLE) -i inventory/inventory.ini all -m wait_for_connection \
	  -a "timeout=300 sleep=5 delay=10" -e "ansible_user=ubuntu ansible_become=yes"
	@echo "[INFO] Waiting for cloud-init..."
	$(ANSIBLE) -i inventory/inventory.ini all -m shell -a "cloud-init status --wait" \
	  -e "ansible_user=ubuntu ansible_become=yes"

.PHONY: deps
deps: ## Install helm/cilium/hubble/tetra/virtctl on the control plane
	$(ANSIBLE_PLAYBOOK) -i inventory/inventory.ini -l kube_control_plane \
	  --user=ubuntu -e 'ansible_python_interpreter=/usr/bin/python3' install-master-deps.yml

.PHONY: cluster
cluster: deps ## Bootstrap Kubernetes with Kubespray (no CNI, no kube-proxy)
	$(call kubespray,cluster.yml)
	$(ON_MASTER) "mkdir -p /home/ubuntu/.kube && cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && chown -R ubuntu:ubuntu /home/ubuntu/.kube"
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
	$(call kubespray,scale.yml)
	$(ON_MASTER) "kubectl get nodes -o wide"

.PHONY: untaint
untaint: ## Make the control plane schedulable (two-node cluster needs this)
	$(ON_MASTER) "kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true"

.PHONY: kubeconfig
kubeconfig: ## Pull the kubeconfig to the laptop under its own context
	@mkdir -p $(HOME)/.kube
	ssh -o StrictHostKeyChecking=no ubuntu@$(MASTER_IP) \
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
crds: ## Gateway API CRDs -- MUST run before `make cilium`
	@# Cilium is installed with gatewayAPI.enabled=true and its operator watches
	@# Gateway/HTTPRoute at startup. If the CRDs are not there yet it goes into
	@# CrashLoopBackOff with a missing-CRD error that reads like a Cilium bug.
	@#
	@# Same shape as prod's bootstrap-crds stage: one targeted apply against the
	@# components state, before the thing that depends on it exists. The rest of
	@# the stack (metrics-server, local-path) would just sit Pending this early,
	@# because there is still no CNI -- so it waits for `make components`.
	$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform apply -auto-approve -target=module.gateway_api_crds -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

.PHONY: cilium
cilium: ## Install Cilium with the lab's flag set, from the control plane
	$(ON_MASTER) "cilium install --version $(CILIUM_VERSION) \
	  --set ipam.mode=kubernetes \
	  --set kubeProxyReplacement=true \
	  --set l2announcements.enabled=true \
	  --set gatewayAPI.enabled=true \
	  --set hubble.relay.enabled=true \
	  --set hubble.ui.enabled=true \
	  --set socketLB.hostNamespaceOnly=true \
	  --set k8sServiceHost=$(MASTER_IP) \
	  --set k8sServicePort=6443 \
	  --set k8sClientRateLimit.qps=50 \
	  --set k8sClientRateLimit.burst=200"
	$(ON_MASTER) "cilium status --wait"

.PHONY: lb
lb: ## Apply the LoadBalancer IP pool and L2 announcement policy
	./scripts/25-cilium-lb-ipam.sh

.PHONY: components
components: ## Apply the add-on stack (Gateway API CRDs, metrics-server, local-path, CoreDNS)
	$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform apply -auto-approve -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

.PHONY: components-plan
components-plan: ## terraform plan for the add-on stack
	$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform plan -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

# ---------------------------------------------------------------------------
# The lab itself
# ---------------------------------------------------------------------------

.PHONY: lab
lab: tetragon ## Deploy Phase 2: Tetragon + attacker + victim
	kubectl apply -f phase2-container-lab/attack/netshoot.yaml
	kubectl -n tetragon-demo wait --for=condition=ready pod --all --timeout=180s
	@echo ""
	@echo "Ready. Detection policy:  make detect"
	@echo "Then mitigation:          make mitigate"

.PHONY: tetragon
tetragon: ## Install Tetragon
	./scripts/30-install-tetragon.sh

.PHONY: detect
detect: ## Phase 2.3 -- apply the detection TracingPolicy
	kubectl apply -f phase2-container-lab/policies/00-monitor-outside-cluster-cidr.yaml

.PHONY: mitigate
mitigate: ## Phase 2.4 -- apply the SIGKILL TracingPolicies
	kubectl apply -f phase2-container-lab/policies/10-kill-network-recon-binaries.yaml
	kubectl apply -f phase2-container-lab/policies/20-kill-tcpdump.yaml

.PHONY: unmitigate
unmitigate: ## Drop the cluster-wide kill policies (REQUIRED before `make kubevirt`)
	kubectl delete tracingpolicy kill-network-recon-binaries --ignore-not-found
	kubectl delete tracingpolicy kill-tcpdump --ignore-not-found

.PHONY: kubevirt
kubevirt: unmitigate ## Phase 3 (DRAFT) -- KubeVirt, the VM, Gateway and client
	./scripts/40-install-kubevirt.sh
	kubectl apply -f phase3-kubevirt-lab/10-nginx-vm.yaml
	kubectl apply -f phase3-kubevirt-lab/20-service.yaml
	kubectl apply -f phase3-kubevirt-lab/30-gateway-httproute.yaml
	kubectl apply -f phase3-kubevirt-lab/40-tmp-client.yaml
	@echo ""
	@echo "VM is booting -- cloud-init installs nginx, allow ~4 minutes."
	@echo "Watch:  kubectl -n kubevirt-demo get vmi -w"

.PHONY: events
events: ## Stream Tetragon events (the 'terminal 2' of the talk)
	kubectl exec -n kube-system ds/tetragon -c tetragon -- tetra getevents -o compact

.PHONY: status
status: ## Where is everything?
	@$(ON_MASTER) "cilium status --brief" || true
	@kubectl get nodes -o wide 2>/dev/null || true
	@kubectl get tracingpolicies 2>/dev/null || true
	@kubectl -n kubevirt-demo get vmi 2>/dev/null || true

.PHONY: preflight
preflight: ## Run the night-before checks
	@echo "── Cilium ─────────────────────────────"
	@$(ON_MASTER) "cilium status --wait"
	@echo "── Nodes ──────────────────────────────"
	@kubectl get nodes
	@echo "── Static kprobe symbols ──────────────"
	@$(ANSIBLE) -i inventory/inventory.ini all -m shell \
	  -e "ansible_user=ubuntu ansible_become=yes" \
	  -a 'grep -wcE "raw_sendmsg|packet_sendmsg" /proc/kallsyms'
	@echo "── Nested virt (Phase 3) ──────────────"
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
	-$(MAKE) destroy-components
	$(MAKE) destroy-vms
	@echo "Lab destroyed."

.PHONY: destroy-components
destroy-components: ## terraform destroy the add-on stack only
	$(call tf,components,terraform init $(TF_INIT_ARGS) && terraform destroy -auto-approve -var=kube_config_path=/tmp/.kube/bsides-lab.conf)

.PHONY: reset
reset: ## Kubespray reset.yml -- wipe Kubernetes, keep the VMs
	$(call kubespray,--extra-vars reset_confirmation=yes reset.yml)

.PHONY: destroy-vms
destroy-vms: ## terraform destroy the two VMs
	$(call tf,vms,terraform init $(TF_INIT_ARGS) && terraform destroy -auto-approve)

.PHONY: clean
clean: ## Remove local terraform caches and the lab kubeconfig
	rm -rf vms/.terraform components/.terraform
	rm -f $(HOME)/.kube/bsides-lab.conf
