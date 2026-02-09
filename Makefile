# HyperFleet CLM - Full Installation Makefile
# Usage: make help

NAMESPACE        ?= hyperfleet
MAESTRO_NS       ?= maestro
KUBECONFIG       ?= $(HOME)/.kube/config
TF_ENV           ?= dev
TF_BACKEND       ?= envs/gke/$(TF_ENV).tfbackend
TF_VARS          ?= envs/gke/$(TF_ENV).tfvars
GCP_PROJECT_ID   ?= hcm-hyperfleet
BROKER_TYPE      ?= googlepubsub
REGISTRY         ?= quay.io/openshift-hyperfleet
IMAGE_TAG        ?= v0.1.0
API_TAG          ?= $(IMAGE_TAG)
SENTINEL_TAG     ?= $(IMAGE_TAG)
ADAPTER_TAG      ?= $(IMAGE_TAG)

HELM_DIR         := helm
TF_DIR           := terraform
GENERATED_DIR    := generated-values-from-terraform

# ──────────────────────────────────────────────
# Prerequisite checks
# ──────────────────────────────────────────────

.PHONY: check-helm
check-helm: ## Verify helm and helm-git plugin are installed
	@command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is not installed"; exit 1; }
	@helm plugin list | grep -q "helm-git" || { echo "ERROR: helm-git plugin is not installed. Install with: helm plugin install https://github.com/aslafy-z/helm-git"; exit 1; }
	@echo "OK: helm and helm-git plugin found"

.PHONY: check-kubectl
check-kubectl: ## Verify kubectl is installed and context is set
	@command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is not installed"; exit 1; }
	@kubectl config current-context >/dev/null 2>&1 || { echo "ERROR: no kubectl context set"; exit 1; }
	@echo "OK: kubectl found, context: $$(kubectl config current-context)"

.PHONY: check-terraform
check-terraform: ## Verify terraform is installed
	@command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform is not installed"; exit 1; }
	@echo "OK: terraform found"

.PHONY: check-tf-files
check-tf-files: ## Verify terraform env files exist
	@test -f $(TF_DIR)/$(TF_BACKEND) || { echo "ERROR: backend file not found: $(TF_DIR)/$(TF_BACKEND)";  echo "Create a copy from $(TF_DIR)/$(TF_BACKEND).example and customize it"; exit 1; }
	@test -f $(TF_DIR)/$(TF_VARS) || { echo "ERROR: tfvars file not found: $(TF_DIR)/$(TF_VARS)";  echo "Create a copy from $(TF_DIR)/$(TF_VARS).example and customize it"; exit 1; }
	@echo "OK: terraform env files found for $(TF_ENV)"

.PHONY: check-namespace
check-namespace: check-kubectl ## Create namespace if it doesn't exist
	@kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	@echo "OK: namespace $(NAMESPACE) ready"

.PHONY: check-maestro-namespace
check-maestro-namespace: check-kubectl ## Create maestro namespace if it doesn't exist
	@kubectl get namespace $(MAESTRO_NS) >/dev/null 2>&1 || kubectl create namespace $(MAESTRO_NS)
	@echo "OK: namespace $(MAESTRO_NS) ready"

# ──────────────────────────────────────────────
# Terraform → cluster credentials & Helm values
# ──────────────────────────────────────────────

.PHONY: get-credentials
get-credentials: check-terraform ## Configure kubectl credentials from Terraform outputs
	@echo "Fetching cluster credentials..."
	@eval $$(cd $(TF_DIR) && terraform output -raw connect_command)
	@echo "OK: kubectl configured"

.PHONY: tf-helm-values
tf-helm-values: check-terraform ## Generate Helm override values from Terraform outputs
	./scripts/tf-helm-values.sh --tf-dir $(TF_DIR) --out-dir $(GENERATED_DIR) --broker-type $(BROKER_TYPE)

.PHONY: clean-generated
clean-generated: ## Remove generated Helm values
	rm -rf $(GENERATED_DIR)
	@echo "OK: cleaned generated values"

# ──────────────────────────────────────────────
# Component install targets
# ──────────────────────────────────────────────

MAESTRO_CONSUMER ?= cluster1

.PHONY: install-maestro
install-maestro: check-helm check-kubectl check-maestro-namespace ## Install Maestro (server + agent)
	helm dependency update $(HELM_DIR)/maestro
	helm upgrade --install $(MAESTRO_NS)-maestro $(HELM_DIR)/maestro \
		--namespace $(MAESTRO_NS) \
		--kubeconfig $(KUBECONFIG) \
		--set agent.messageBroker.mqtt.host=maestro-mqtt.$(MAESTRO_NS) \
		--wait --timeout 5m

.PHONY: create-maestro-consumer
create-maestro-consumer: check-kubectl ## Create a Maestro consumer (requires Maestro server running)
	@echo "Creating Maestro consumer '$(MAESTRO_CONSUMER)'..."
	@kubectl run maestro-consumer-create --rm -i --restart=Never \
		--namespace $(MAESTRO_NS) \
		--kubeconfig $(KUBECONFIG) \
		--image=curlimages/curl:latest -- \
		curl -s -X POST \
		-H "Content-Type: application/json" \
		http://maestro.$(MAESTRO_NS).svc.cluster.local:8000/api/maestro/v1/consumers \
		-d '{"name": "$(MAESTRO_CONSUMER)"}'
	@echo ""
	@echo "OK: consumer '$(MAESTRO_CONSUMER)' created"

.PHONY: install-api
install-api: check-helm check-kubectl check-namespace ## Install HyperFleet API
	helm dependency update $(HELM_DIR)/api
	helm upgrade --install $(NAMESPACE)-api $(HELM_DIR)/api \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		$(if $(REGISTRY),--set hyperfleet-api.image.registry=$(REGISTRY)) \
		--set hyperfleet-api.image.tag=$(API_TAG)

.PHONY: install-sentinel-clusters
install-sentinel-clusters: check-helm check-kubectl check-namespace ## Install Sentinel for clusters
	helm dependency update $(HELM_DIR)/sentinel-clusters
	helm upgrade --install $(NAMESPACE)-sentinel-clusters $(HELM_DIR)/sentinel-clusters \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set sentinel.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set sentinel.image.registry=$(REGISTRY)) \
		--set sentinel.image.tag=$(SENTINEL_TAG) \
		$(if $(wildcard $(GENERATED_DIR)/sentinel-clusters.yaml),--values $(GENERATED_DIR)/sentinel-clusters.yaml)

.PHONY: install-sentinel-nodepools
install-sentinel-nodepools: check-helm check-kubectl check-namespace ## Install Sentinel for nodepools
	helm dependency update $(HELM_DIR)/sentinel-nodepools
	helm upgrade --install $(NAMESPACE)-sentinel-nodepools $(HELM_DIR)/sentinel-nodepools \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set sentinel.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set sentinel.image.registry=$(REGISTRY)) \
		--set sentinel.image.tag=$(SENTINEL_TAG) \
		$(if $(wildcard $(GENERATED_DIR)/sentinel-nodepools.yaml),--values $(GENERATED_DIR)/sentinel-nodepools.yaml)

.PHONY: install-adapter1
install-adapter1: check-helm check-kubectl check-namespace ## Install adapter1
	helm dependency update $(HELM_DIR)/adapter1
	helm upgrade --install $(NAMESPACE)-adapter1 $(HELM_DIR)/adapter1 \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter1/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter1/adapter-task-config.yaml \
		$(if $(wildcard $(GENERATED_DIR)/adapter1.yaml),--values $(GENERATED_DIR)/adapter1.yaml)

.PHONY: install-adapter2
install-adapter2: check-helm check-kubectl check-namespace ## Install adapter2
	helm dependency update $(HELM_DIR)/adapter2
	helm upgrade --install $(NAMESPACE)-adapter2 $(HELM_DIR)/adapter2 \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter2/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter2/adapter-task-config.yaml \
		$(if $(wildcard $(GENERATED_DIR)/adapter2.yaml),--values $(GENERATED_DIR)/adapter2.yaml)

.PHONY: install-adapter3
install-adapter3: check-helm check-kubectl check-namespace ## Install adapter3
	helm dependency update $(HELM_DIR)/adapter3
	helm upgrade --install $(NAMESPACE)-adapter3 $(HELM_DIR)/adapter3 \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter3/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter3/adapter-task-config.yaml \
		$(if $(wildcard $(GENERATED_DIR)/adapter3.yaml),--values $(GENERATED_DIR)/adapter3.yaml)

.PHONY: install-terraform
install-terraform: check-terraform check-tf-files ## Run Terraform init and apply
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	cd $(TF_DIR) && terraform apply -var-file=$(TF_VARS)

# ──────────────────────────────────────────────
# Aggregate install targets
# ──────────────────────────────────────────────

.PHONY: install-sentinels
install-sentinels: install-sentinel-clusters install-sentinel-nodepools ## Install all sentinels

.PHONY: install-adapters
install-adapters: install-adapter1 install-adapter2 install-adapter3 ## Install all adapters

.PHONY: install-hyperfleet
install-hyperfleet: install-api install-sentinels install-adapters ## Install API + sentinels + adapters (no maestro, no terraform)

.PHONY: install-all
install-all: install-terraform get-credentials tf-helm-values install-maestro create-maestro-consumer install-hyperfleet ## Install everything (terraform + hyperfleet + maestro)

# ──────────────────────────────────────────────
# Uninstall targets
# ──────────────────────────────────────────────

.PHONY: uninstall-maestro
uninstall-maestro: ## Uninstall Maestro
	helm uninstall $(MAESTRO_NS)-maestro --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-api
uninstall-api: ## Uninstall HyperFleet API
	helm uninstall $(NAMESPACE)-api --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-sentinel-clusters
uninstall-sentinel-clusters: ## Uninstall Sentinel for clusters
	helm uninstall $(NAMESPACE)-sentinel-clusters --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-sentinel-nodepools
uninstall-sentinel-nodepools: ## Uninstall Sentinel for nodepools
	helm uninstall $(NAMESPACE)-sentinel-nodepools --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-adapter1
uninstall-adapter1: ## Uninstall adapter1
	helm uninstall $(NAMESPACE)-adapter1 --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-adapter2
uninstall-adapter2: ## Uninstall adapter2
	helm uninstall $(NAMESPACE)-adapter2 --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-adapter3
uninstall-adapter3: ## Uninstall adapter3
	helm uninstall $(NAMESPACE)-adapter3 --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) || true

.PHONY: uninstall-hyperfleet
uninstall-hyperfleet: uninstall-api uninstall-sentinel-clusters uninstall-sentinel-nodepools uninstall-adapter1 uninstall-adapter2 uninstall-adapter3 ## Uninstall API + sentinels + adapters (no maestro)

.PHONY: uninstall-all
uninstall-all: uninstall-maestro uninstall-hyperfleet ## Uninstall everything

# ──────────────────────────────────────────────
# Utility targets
# ──────────────────────────────────────────────

.PHONY: deps
deps: check-helm ## Run helm dependency update for all charts
	@for chart in $(HELM_DIR)/*/; do \
		echo "Updating dependencies for $$chart..."; \
		helm dependency update "$$chart"; \
	done

.PHONY: status
status: check-kubectl ## Show helm releases and pod status
	@echo "=== Helm Releases ==="
	@helm list --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) 2>/dev/null || true
	@helm list --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) 2>/dev/null || true
	@echo ""
	@echo "=== Pods ==="
	@kubectl get pods --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) 2>/dev/null || true
	@kubectl get pods --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) 2>/dev/null || true

.PHONY: help
help: ## Print available targets
	@echo "HyperFleet CLM - Full Installation"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  NAMESPACE        Kubernetes namespace for HyperFleet components (default: hyperfleet)"
	@echo "  MAESTRO_NS       Kubernetes namespace for Maestro (default: maestro)"
	@echo "  KUBECONFIG       Path to kubeconfig (default: ~/.kube/config)"
	@echo "  TF_ENV           Terraform environment (default: dev)"
	@echo "  GCP_PROJECT_ID   GCP project ID (default: hcm-hyperfleet)"
	@echo "  BROKER_TYPE      Message broker type (default: googlepubsub)"
	@echo "  REGISTRY         Override image registry for all components (e.g. quay.io/myuser)"
	@echo "  IMAGE_TAG        Default image tag for all components (default: v0.1.0)"
	@echo "  API_TAG          Override image tag for API (default: IMAGE_TAG)"
	@echo "  SENTINEL_TAG     Override image tag for sentinels (default: IMAGE_TAG)"
	@echo "  ADAPTER_TAG      Override image tag for adapters (default: IMAGE_TAG)"
	@echo "  MAESTRO_CONSUMER Maestro consumer name (default: cluster1)"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
