# HyperFleet CLM - Full Installation Makefile
# Usage: make help

.DEFAULT_GOAL := help

NAMESPACE        ?= hyperfleet
MAESTRO_NS       ?= maestro
KUBECONFIG       ?= $(HOME)/.kube/config
TF_ENV           ?= dev
TF_BACKEND       ?= envs/gke/$(TF_ENV).tfbackend
TF_VARS          ?= envs/gke/$(TF_ENV).tfvars
GCP_PROJECT_ID   ?= hcm-hyperfleet
BROKER_TYPE      ?= googlepubsub
RABBITMQ_URL     ?= amqp://guest:guest@rabbitmq:5672/
REGISTRY             ?= registry.ci.openshift.org
API_REPOSITORY       ?= ci/hyperfleet-api
SENTINEL_REPOSITORY  ?= ci/hyperfleet-sentinel
ADAPTER_REPOSITORY   ?= ci/hyperfleet-adapter
API_IMAGE_TAG        ?= release-0.2
SENTINEL_IMAGE_TAG   ?= release-0.2
ADAPTER_IMAGE_TAG    ?= release-0.2
DRY_RUN            ?=
AUTO_APPROVE       ?=
# Derived flags from boolean variables (only true/1 are treated as truthy)
TRUTHY_VALUES     := true 1
DRY_RUN_FLAG      := $(if $(filter $(TRUTHY_VALUES),$(strip $(DRY_RUN))),--dry-run)
AUTO_APPROVE_FLAG := $(if $(filter $(TRUTHY_VALUES),$(strip $(AUTO_APPROVE))),-auto-approve)

# Chart source configuration (helm-git plugin)
# Chart refs are independent of image tags so that overriding an image tag
# (e.g., make install-api API_IMAGE_TAG=dev-abc123) does not retarget charts.
# Override chart refs explicitly when needed:
#   make install-adapter1 ADAPTER_CHART_REF=release-0.2
#   make install-adapter1 CHART_ORG=myuser
CHART_ORG          ?= openshift-hyperfleet
API_CHART_REF      ?= release-0.2
SENTINEL_CHART_REF ?= release-0.2
ADAPTER_CHART_REF  ?= release-0.2

HELM_DIR         := helm
TF_DIR           ?= terraform
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
tf-helm-values: $(if $(filter googlepubsub,$(BROKER_TYPE)),check-terraform) ## Generate Helm override values (from Terraform for googlepubsub, from variables for rabbitmq)
	./scripts/tf-helm-values.sh --out-dir $(GENERATED_DIR) --broker-type $(BROKER_TYPE) \
		$(if $(filter googlepubsub,$(BROKER_TYPE)),--tf-dir $(TF_DIR)) \
		$(if $(filter rabbitmq,$(BROKER_TYPE)),--rabbitmq-url $(RABBITMQ_URL) --namespace $(NAMESPACE))

.PHONY: clean-generated
clean-generated: ## Remove generated Helm values
	rm -rf $(GENERATED_DIR)
	@echo "OK: cleaned generated values"

# ──────────────────────────────────────────────
# Component install targets
# ──────────────────────────────────────────────

MAESTRO_CONSUMER ?= cluster1
MANIFESTS_DIR    := manifests

.PHONY: install-rabbitmq
install-rabbitmq: check-kubectl check-namespace ## Install RabbitMQ (dev only, for BROKER_TYPE=rabbitmq)
	kubectl apply -f $(MANIFESTS_DIR)/rabbitmq.yaml --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG)
	@echo "Waiting for RabbitMQ to be ready..."
	@kubectl wait --for=condition=ready pod -l app=rabbitmq --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) --timeout=120s
	@echo "OK: RabbitMQ is ready"

.PHONY: install-maestro
install-maestro: check-helm check-kubectl check-maestro-namespace ## Install Maestro (server + agent)
	helm dependency update $(HELM_DIR)/maestro
	@echo "Installing Maestro..."
	
	if ! helm upgrade --install $(DRY_RUN_FLAG) $(MAESTRO_NS)-maestro $(HELM_DIR)/maestro \
		--namespace $(MAESTRO_NS) \
		--kubeconfig $(KUBECONFIG) \
		--set agent.messageBroker.mqtt.host=maestro-mqtt.$(MAESTRO_NS) \
		--wait --timeout 5m ; then \
		echo "Warning: maestro install failed on kind cluster; continuing"; \
	fi; 
	@echo "Waiting for Maestro pods to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=$(MAESTRO_NS)-maestro --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) --timeout=180s || true
	@echo "OK: Maestro pods are ready"

.PHONY: create-maestro-consumer
create-maestro-consumer: check-kubectl ## Create a Maestro consumer (requires Maestro server running)
	@echo "Creating Maestro consumer '$(MAESTRO_CONSUMER)'..."
	@for i in 1 2 3 4 5; do \
		exists=$$(kubectl exec deploy/maestro --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) -- \
			curl -sS --connect-timeout 5 --max-time 10 http://maestro.$(MAESTRO_NS).svc.cluster.local:8000/api/maestro/v1/consumers \
			2>/dev/null | grep -F -c -- '"name":"$(MAESTRO_CONSUMER)"') 2>/dev/null || true; \
		if [ "$$exists" -gt 0 ]; then \
			echo "OK: consumer '$(MAESTRO_CONSUMER)' already exists"; exit 0; \
		fi; \
		status=$$(kubectl exec deploy/maestro --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) -- \
			curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
			-H "Content-Type: application/json" \
			http://maestro.$(MAESTRO_NS).svc.cluster.local:8000/api/maestro/v1/consumers \
			-d '{"name": "$(MAESTRO_CONSUMER)"}' 2>/dev/null) 2>/dev/null || status="error"; \
		case "$$status" in \
			201) echo "OK: consumer '$(MAESTRO_CONSUMER)' created"; exit 0;; \
			409) echo "WARNING: consumer '$(MAESTRO_CONSUMER)' already exists (race condition)"; exit 0;; \
			*) echo "  Attempt $$i failed (status: $$status), retrying in 5s..."; sleep 5;; \
		esac; \
	done; \
	echo "ERROR: failed to create Maestro consumer after 5 attempts"; exit 1

# set-chart-ref: update the ?ref= and org in a Chart.yaml dependency URL
# Usage: $(call set-chart-ref,<chart-dir>,<ref>)
define set-chart-ref
	@sed -i.bak 's|github.com/[^/]*/|github.com/$(CHART_ORG)/|' $(1)/Chart.yaml
	@sed -i.bak 's|\(?ref=\)[^"]*"|\1$(2)"|' $(1)/Chart.yaml
	@rm -f $(1)/Chart.yaml.bak
	@rm -rf $(1)/charts $(1)/Chart.lock
endef

.PHONY: install-api
install-api: check-helm check-kubectl check-namespace ## Install HyperFleet API
	$(call set-chart-ref,$(HELM_DIR)/api,$(API_CHART_REF))
	helm dependency update $(HELM_DIR)/api
	helm upgrade --install $(DRY_RUN_FLAG) $(NAMESPACE)-api $(HELM_DIR)/api \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		$(if $(REGISTRY),--set hyperfleet-api.image.registry=$(REGISTRY)) \
		$(if $(API_REPOSITORY),--set hyperfleet-api.image.repository=$(API_REPOSITORY)) \
		--set hyperfleet-api.image.tag=$(API_IMAGE_TAG)

.PHONY: install-sentinel-clusters
install-sentinel-clusters: check-helm check-kubectl check-namespace ## Install Sentinel for clusters
	$(call set-chart-ref,$(HELM_DIR)/sentinel-clusters,$(SENTINEL_CHART_REF))
	helm dependency update $(HELM_DIR)/sentinel-clusters
	helm upgrade --install $(DRY_RUN_FLAG) $(NAMESPACE)-sentinel-clusters $(HELM_DIR)/sentinel-clusters \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-sentinel.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-sentinel.image.registry=$(REGISTRY)) \
		$(if $(SENTINEL_REPOSITORY),--set hyperfleet-sentinel.image.repository=$(SENTINEL_REPOSITORY)) \
		--set hyperfleet-sentinel.image.tag=$(SENTINEL_IMAGE_TAG) \
		$(if $(wildcard $(GENERATED_DIR)/sentinel-clusters.yaml),--values $(GENERATED_DIR)/sentinel-clusters.yaml)

.PHONY: install-sentinel-nodepools
install-sentinel-nodepools: check-helm check-kubectl check-namespace ## Install Sentinel for nodepools
	$(call set-chart-ref,$(HELM_DIR)/sentinel-nodepools,$(SENTINEL_CHART_REF))
	helm dependency update $(HELM_DIR)/sentinel-nodepools
	helm upgrade --install $(DRY_RUN_FLAG) $(NAMESPACE)-sentinel-nodepools $(HELM_DIR)/sentinel-nodepools \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-sentinel.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-sentinel.image.registry=$(REGISTRY)) \
		$(if $(SENTINEL_REPOSITORY),--set hyperfleet-sentinel.image.repository=$(SENTINEL_REPOSITORY)) \
		--set hyperfleet-sentinel.image.tag=$(SENTINEL_IMAGE_TAG) \
		$(if $(wildcard $(GENERATED_DIR)/sentinel-nodepools.yaml),--values $(GENERATED_DIR)/sentinel-nodepools.yaml)

.PHONY: install-adapter1
install-adapter1: check-helm check-kubectl check-namespace ## Install adapter1
	$(call set-chart-ref,$(HELM_DIR)/adapter1,$(ADAPTER_CHART_REF))
	helm dependency update $(HELM_DIR)/adapter1
	helm upgrade --install $(DRY_RUN_FLAG) $(NAMESPACE)-adapter1 $(HELM_DIR)/adapter1 \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		$(if $(ADAPTER_REPOSITORY),--set hyperfleet-adapter.image.repository=$(ADAPTER_REPOSITORY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_IMAGE_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter1/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter1/adapter-task-config.yaml \
		$(if $(wildcard $(GENERATED_DIR)/adapter1.yaml),--values $(GENERATED_DIR)/adapter1.yaml)

.PHONY: install-adapter2
install-adapter2: check-helm check-kubectl check-namespace ## Install adapter2
	$(call set-chart-ref,$(HELM_DIR)/adapter2,$(ADAPTER_CHART_REF))
	helm dependency update $(HELM_DIR)/adapter2
	helm upgrade --install $(DRY_RUN_FLAG) $(NAMESPACE)-adapter2 $(HELM_DIR)/adapter2 \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		$(if $(ADAPTER_REPOSITORY),--set hyperfleet-adapter.image.repository=$(ADAPTER_REPOSITORY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_IMAGE_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter2/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter2/adapter-task-config.yaml \
		$(if $(wildcard $(GENERATED_DIR)/adapter2.yaml),--values $(GENERATED_DIR)/adapter2.yaml)

.PHONY: install-adapter3
install-adapter3: check-helm check-kubectl check-namespace ## Install adapter3
	$(call set-chart-ref,$(HELM_DIR)/adapter3,$(ADAPTER_CHART_REF))
	helm dependency update $(HELM_DIR)/adapter3
	helm upgrade --install $(DRY_RUN_FLAG) $(NAMESPACE)-adapter3 $(HELM_DIR)/adapter3 \
		--namespace $(NAMESPACE) \
		--kubeconfig $(KUBECONFIG) \
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		$(if $(ADAPTER_REPOSITORY),--set hyperfleet-adapter.image.repository=$(ADAPTER_REPOSITORY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_IMAGE_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter3/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter3/adapter-task-config.yaml \
		$(if $(wildcard $(GENERATED_DIR)/adapter3.yaml),--values $(GENERATED_DIR)/adapter3.yaml)

.PHONY: install-terraform
install-terraform: check-terraform check-tf-files ## Run Terraform init and apply
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	cd $(TF_DIR) && terraform apply -var-file=$(TF_VARS) $(AUTO_APPROVE_FLAG)

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
install-all: install-terraform get-credentials tf-helm-values install-maestro create-maestro-consumer install-hyperfleet ## Full GCP install (terraform + googlepubsub + hyperfleet + maestro)

.PHONY: install-all-rabbitmq
install-all-rabbitmq: BROKER_TYPE = rabbitmq
install-all-rabbitmq: install-rabbitmq tf-helm-values install-hyperfleet install-maestro create-maestro-consumer ## Full RabbitMQ install (rabbitmq + hyperfleet + maestro, no terraform)

# ──────────────────────────────────────────────
# CI validation targets
# ──────────────────────────────────────────────

# --- Layer 1: Static validation ---

.PHONY: validate-terraform
validate-terraform: check-terraform ## Validate Terraform syntax and formatting
	cd $(TF_DIR) && \
		terraform init -backend=false && \
		terraform fmt -check -recursive -diff && \
		terraform validate

.PHONY: lint-helm
lint-helm: check-helm deps ## Lint all Helm charts
	@for chart in $(HELM_DIR)/*/; do \
		echo "Linting $$chart..."; \
		helm lint "$$chart" || exit 1; \
	done

.PHONY: lint-shellcheck
lint-shellcheck: ## Validate shell scripts with shellcheck
	@if command -v shellcheck >/dev/null 2>&1; then \
		find . -name '*.sh' -not -path './.terraform/*' -not -path './.git/*' -exec shellcheck {} +; \
	elif [ -n "$$CI" ]; then \
		echo "ERROR: shellcheck is required in CI but not installed"; exit 1; \
	else \
		echo "WARN: shellcheck not installed, skipping"; \
	fi

.PHONY: ci-validate
ci-validate: validate-terraform lint-helm lint-shellcheck ## Layer 1: Static validation

# --- Layer 2: Dry-run validation ---

.PHONY: plan-terraform
plan-terraform: check-terraform check-tf-files ## Run terraform plan (preview only, no apply)
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	cd $(TF_DIR) && terraform plan -var-file=$(TF_VARS)

# validate-chart: validate a single Helm chart with helm template
# Usage: $(call validate-chart,<chart-name>,<chart-ref>,<helm-template-args>)
define validate-chart
	@echo "Validating $(1) chart..."
	$(call set-chart-ref,$(HELM_DIR)/$(1),$(2))
	helm dependency update $(HELM_DIR)/$(1)
	helm template $(NAMESPACE)-$(1) $(HELM_DIR)/$(1) $(3) > /dev/null
endef

.PHONY: validate-helm-charts
validate-helm-charts: check-helm ## Render all Helm charts with helm template (no cluster required)
	$(call validate-chart,api,$(API_CHART_REF),\
		$(if $(REGISTRY),--set hyperfleet-api.image.registry=$(REGISTRY)) \
		$(if $(API_REPOSITORY),--set hyperfleet-api.image.repository=$(API_REPOSITORY)) \
		--set hyperfleet-api.image.tag=$(API_IMAGE_TAG))

	$(call validate-chart,sentinel-clusters,$(SENTINEL_CHART_REF),\
		--set hyperfleet-sentinel.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-sentinel.image.registry=$(REGISTRY)) \
		$(if $(SENTINEL_REPOSITORY),--set hyperfleet-sentinel.image.repository=$(SENTINEL_REPOSITORY)) \
		--set hyperfleet-sentinel.image.tag=$(SENTINEL_IMAGE_TAG))

	$(call validate-chart,sentinel-nodepools,$(SENTINEL_CHART_REF),\
		--set hyperfleet-sentinel.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-sentinel.image.registry=$(REGISTRY)) \
		$(if $(SENTINEL_REPOSITORY),--set hyperfleet-sentinel.image.repository=$(SENTINEL_REPOSITORY)) \
		--set hyperfleet-sentinel.image.tag=$(SENTINEL_IMAGE_TAG))

	$(call validate-chart,adapter1,$(ADAPTER_CHART_REF),\
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		$(if $(ADAPTER_REPOSITORY),--set hyperfleet-adapter.image.repository=$(ADAPTER_REPOSITORY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_IMAGE_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter1/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter1/adapter-task-config.yaml)

	$(call validate-chart,adapter2,$(ADAPTER_CHART_REF),\
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		$(if $(ADAPTER_REPOSITORY),--set hyperfleet-adapter.image.repository=$(ADAPTER_REPOSITORY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_IMAGE_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter2/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter2/adapter-task-config.yaml)

	$(call validate-chart,adapter3,$(ADAPTER_CHART_REF),\
		--set hyperfleet-adapter.broker.type=$(BROKER_TYPE) \
		$(if $(REGISTRY),--set hyperfleet-adapter.image.registry=$(REGISTRY)) \
		$(if $(ADAPTER_REPOSITORY),--set hyperfleet-adapter.image.repository=$(ADAPTER_REPOSITORY)) \
		--set hyperfleet-adapter.image.tag=$(ADAPTER_IMAGE_TAG) \
		--set-file hyperfleet-adapter.adapterConfig.yaml=$(HELM_DIR)/adapter3/adapter-config.yaml \
		--set-file hyperfleet-adapter.adapterTaskConfig.yaml=$(HELM_DIR)/adapter3/adapter-task-config.yaml)

	helm dependency update $(HELM_DIR)/maestro
	@echo "Validating maestro chart..."
	helm template $(MAESTRO_NS)-maestro $(HELM_DIR)/maestro \
		--set agent.messageBroker.mqtt.host=maestro-mqtt.$(MAESTRO_NS) > /dev/null
	@echo "OK: all Helm charts rendered successfully"

.PHONY: ci-dry-run
ci-dry-run: ci-validate ## Layer 2: Static + dry-run validation (no credentials required)
	$(MAKE) validate-helm-charts BROKER_TYPE=rabbitmq
	$(MAKE) validate-helm-charts BROKER_TYPE=googlepubsub

# --- Layer 3: Full integration test ---

.PHONY: health-check
health-check: check-kubectl ## Verify all HyperFleet components are healthy
	@echo "Checking HyperFleet components..."
	@deploys=$$(kubectl get deployments --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) -o name) && \
		[ -n "$$deploys" ] || { echo "ERROR: no deployments found in namespace $(NAMESPACE)"; exit 1; }; \
		for deploy in $$deploys; do \
			echo "  Waiting for $$deploy..."; \
			kubectl rollout status $$deploy --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) --timeout=300s || exit 1; \
		done
	@echo "Checking Maestro components..."
	@deploys=$$(kubectl get deployments --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) -o name) && \
		[ -n "$$deploys" ] || { echo "ERROR: no deployments found in namespace $(MAESTRO_NS)"; exit 1; }; \
		for deploy in $$deploys; do \
			echo "  Waiting for $$deploy..."; \
			kubectl rollout status $$deploy --namespace $(MAESTRO_NS) --kubeconfig $(KUBECONFIG) --timeout=300s || exit 1; \
		done
	@echo "OK: all components healthy"

.PHONY: destroy-terraform
destroy-terraform: check-terraform check-tf-files ## Destroy Terraform-managed infrastructure
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	# Always use -auto-approve to prevent CI cleanup from hanging on interactive prompt
	cd $(TF_DIR) && terraform destroy -var-file=$(TF_VARS) -auto-approve

.PHONY: ci-test
ci-test: install-all health-check ## Layer 3: Full integration test

.PHONY: ci-cleanup
ci-cleanup: uninstall-all destroy-terraform ## Layer 3: Cleanup after integration test

# ──────────────────────────────────────────────
# Uninstall targets
# ──────────────────────────────────────────────

.PHONY: uninstall-rabbitmq
uninstall-rabbitmq: check-kubectl ## Uninstall RabbitMQ
	kubectl delete -f $(MANIFESTS_DIR)/rabbitmq.yaml --namespace $(NAMESPACE) --kubeconfig $(KUBECONFIG) --ignore-not-found

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
	@echo "  BROKER_TYPE      Message broker type: googlepubsub or rabbitmq (default: googlepubsub)"
	@echo "  RABBITMQ_URL     RabbitMQ connection URL (default: amqp://guest:guest@rabbitmq:5672/)"
	@echo "  REGISTRY           Override image registry for all components (default: registry.ci.openshift.org)"
	@echo "  API_REPOSITORY     Override API image repository (default: ci/hyperfleet-api)"
	@echo "  SENTINEL_REPOSITORY Override sentinel image repository (default: ci/hyperfleet-sentinel)"
	@echo "  ADAPTER_REPOSITORY Override adapter image repository (default: ci/hyperfleet-adapter)"
	@echo "  API_IMAGE_TAG      Image tag for API (default: release-0.2)"
	@echo "  SENTINEL_IMAGE_TAG Image tag for sentinels (default: release-0.2)"
	@echo "  ADAPTER_IMAGE_TAG  Image tag for adapters (default: release-0.2)"
	@echo "  CHART_ORG          GitHub org for helm chart repos (default: openshift-hyperfleet)"
	@echo "  API_CHART_REF      Git ref for API helm chart source (default: release-0.2)"
	@echo "  SENTINEL_CHART_REF Git ref for sentinel helm chart source (default: release-0.2)"
	@echo "  ADAPTER_CHART_REF  Git ref for adapter helm chart source (default: release-0.2)"
	@echo "  MAESTRO_CONSUMER Maestro consumer name (default: cluster1)"
	@echo "  DRY_RUN          Set to true or 1 for Helm dry-run mode (default: empty)"
	@echo "  AUTO_APPROVE     Set to true or 1 for non-interactive Terraform (default: empty)"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
