
.DEFAULT_GOAL := help

# Possible envs are gcp, e2e-gcp, kind, e2e-kind
# Default to gcp
HELMFILE_ENV ?= gcp


ifeq ($(findstring gcp,$(HELMFILE_ENV)),)
	-include env.kind
else
	-include env.gcp
endif

export
GIT_SHA ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
TF_ENV           ?= dev
TF_BACKEND       ?= envs/gke/$(TF_ENV).tfbackend
TF_VARS          ?= envs/gke/$(TF_ENV).tfvars

DRY_RUN            ?=
AUTO_APPROVE       ?=
# Derived flags from boolean variables (only true/1 are treated as truthy)
TRUTHY_VALUES     := true 1
DRY_RUN_FLAG      := $(if $(filter $(TRUTHY_VALUES),$(strip $(DRY_RUN))),--dry-run)
AUTO_APPROVE_FLAG := $(if $(filter $(TRUTHY_VALUES),$(strip $(AUTO_APPROVE))),-auto-approve)
BUILD_IMAGES_ENABLED := $(if $(filter $(TRUTHY_VALUES),$(strip $(BUILD_IMAGES))),1,)


# Default Dirs
MANIFESTS_DIR    ?= manifests
HELM_DIR         ?= helm
TF_DIR           ?= terraform

GENERATED_RABBITMQ_DIR ?= generated-values-rabbitmq
GENERATED_DIR ?= generated-values-from-terraform
RABBITMQ_URL ?=  "amqp://guest:guest@rabbitmq:5672"
MAESTRO_CONSUMER ?= cluster1
MAESTRO_NAMESPACE ?= maestro
KUBECONFIG ?= $(HOME)/.kube/config

CLEANER_NAMESPACE    ?= $(NAMESPACE)
CLEANER_SCHEDULE     ?= 0 * * * *
CLEANER_LABEL_SELECTOR ?= hyperfleet.io/cluster-id hyperfleet.io/test-run
CLEANER_AGE_MINUTES  ?= 180
CLEANER_MAESTRO_URL  ?= http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000

# ==== Terraform Targets ====
.PHONY: install-terraform
install-terraform: check-terraform check-tf-files ## Run Terraform init and apply
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	cd $(TF_DIR) && terraform apply -var-file=$(TF_VARS) $(AUTO_APPROVE_FLAG) -lock=false

.PHONY: plan-terraform
plan-terraform: check-terraform check-tf-files ## Run terraform plan (preview only, no apply)
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	cd $(TF_DIR) && terraform plan -var-file=$(TF_VARS)

.PHONY: destroy-terraform
destroy-terraform: check-terraform check-tf-files ## Destroy Terraform-managed infrastructure
	cd $(TF_DIR) && terraform init -backend-config=$(TF_BACKEND)
	# Always use -auto-approve to prevent CI cleanup from hanging on interactive prompt
	cd $(TF_DIR) && terraform destroy -var-file=$(TF_VARS) -auto-approve -lock=false

.PHONY: get-credentials
get-credentials: check-terraform ## Configure kubectl credentials from Terraform outputs
	@echo "Fetching cluster credentials..."
	@eval $$(cd $(TF_DIR) && terraform output -raw connect_command)
	@echo "OK: kubectl configured"


# ==== Kind Targets ====
.PHONY: create-kind-cluster
create-kind-cluster: check-kind ## Create a new kind cluster or export kubeconfig if exists
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "kind cluster '$(KIND_CLUSTER_NAME)' already exists ..."; \
	else \
		echo "Creating new kind cluster '$(KIND_CLUSTER_NAME)'..."; \
		kind create cluster --name $(KIND_CLUSTER_NAME); \
	fi
	@kind export kubeconfig --name $(KIND_CLUSTER_NAME) --kubeconfig $(KUBECONFIG)
	@kubectl config use-context kind-$(KIND_CLUSTER_NAME) --kubeconfig $(KUBECONFIG)
	@echo "OK: kubeconfig exported and context set for cluster $(KIND_CLUSTER_NAME)" \

.PHONY: delete-kind-cluster
delete-kind-cluster: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER_NAME)
	@echo "OK: deleted kind cluster $(KIND_CLUSTER_NAME)"

.PHONY: kind-build-images
kind-build-images: check-kind check-kubectl-context ## Build and load images to kind (skipped if BUILD_IMAGES=true in env.kind)
ifeq ($(BUILD_IMAGES), true)
	@./scripts/kind-build-images.sh
else
	@echo ""
	@echo "[NOTE: Skipping building images for kind cluster]"
	@echo "To enable kind image builds set BUILD_IMAGES=true in env.kind"
endif

# ==== Helmfile Targets ====
.PHONY: template-helmfile
template-helmfile: check-helmfile ## Template the helmfile for the current environment
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) template

.PHONY: build-helmfile
build-helmfile: check-helmfile ## Build the helmfile for the current environment
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) build

.PHONY: lint-helmfile
lint-helmfile: check-helmfile ## Lint the helmfile for the current environment
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) lint

# ==== Maestro Targets ====
# NOTE: This is a workaround to install the AppliedManifestWorks CRD manually if there are issues installing via Helm - https://github.com/openshift-online/maestro/blob/main/charts/maestro-agent/templates/crd.yaml is not working as expected
.PHONY: install-applied-manifest-crd
install-applied-manifest-crd: check-kubectl ## Install AppliedManifestWorks CRD (for Maestro)
	@echo "Installing AppliedManifestWorks CRD..."
	@kubectl apply -f https://raw.githubusercontent.com/open-cluster-management-io/api/main/work/v1/0000_01_work.open-cluster-management.io_appliedmanifestworks.crd.yaml
	@echo "OK: AppliedManifestWorks CRD installed"

.PHONY: install-priority-classes
install-priority-classes: check-kubectl ## Install PriorityClasses for critical infrastructure pods
	@kubectl apply -f "$(MANIFESTS_DIR)/priority-classes.yaml"
	@echo "OK: PriorityClasses applied"

.PHONY: install-maestro
install-maestro: check-helm check-kubectl check-maestro-namespace install-applied-manifest-crd install-priority-classes ## Install Maestro (server + agent)
	helm dependency update $(HELM_DIR)/maestro
	@echo "Installing Maestro..."
	if ! helm upgrade --install $(DRY_RUN_FLAG) $(MAESTRO_NAMESPACE)-maestro $(HELM_DIR)/maestro \
		--namespace $(MAESTRO_NAMESPACE) \
		--set agent.installWorkCRDs=false \
		--set agent.messageBroker.mqtt.host=maestro-mqtt.$(MAESTRO_NAMESPACE) \
		--wait --timeout 5m ; then \
		echo "Warning: maestro install failed on cluster; continuing"; \
	fi; 
	@echo "Waiting for Maestro pods to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=$(MAESTRO_NAMESPACE)-maestro --namespace $(MAESTRO_NAMESPACE) --timeout=180s || true
	@echo "OK: Maestro pods are ready"


.PHONY: create-maestro-consumer
create-maestro-consumer: check-kubectl check-maestro-namespace check-jq ## Create a Maestro consumer (requires Maestro server running)
	@echo "Validating MAESTRO_CONSUMER name..."
	@if ! echo "$(MAESTRO_CONSUMER)" | grep -qE '^[a-zA-Z0-9_-]+$$'; then \
		echo "ERROR: MAESTRO_CONSUMER='$(MAESTRO_CONSUMER)' contains invalid characters"; \
		echo "       Only alphanumerics, dashes, and underscores are allowed"; \
		exit 1; \
	fi
	@echo "Creating Maestro consumer '$(MAESTRO_CONSUMER)'..."
	@payload=$$(echo '{}' | jq -c --arg name "$(MAESTRO_CONSUMER)" '{name: $$name}'); \
	for i in 1 2 3 4 5; do \
		exists=$$(kubectl exec deploy/maestro --namespace $(MAESTRO_NAMESPACE) -- \
			curl -sS --connect-timeout 5 --max-time 10 http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000/api/maestro/v1/consumers \
			2>/dev/null | jq --arg name "$(MAESTRO_CONSUMER)" '[.items[]? | select(.name == $$name)] | length') 2>/dev/null || exists=0; \
		if [ "$$exists" -gt 0 ]; then \
			echo "OK: consumer '$(MAESTRO_CONSUMER)' already exists"; exit 0; \
		fi; \
		status=$$(kubectl exec deploy/maestro --namespace $(MAESTRO_NAMESPACE) --kubeconfig $(KUBECONFIG) -- \
			curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
			-H "Content-Type: application/json" \
			http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000/api/maestro/v1/consumers \
			-d "$$payload" 2>/dev/null) 2>/dev/null || status="error"; \
		case "$$status" in \
			201) echo "OK: consumer '$(MAESTRO_CONSUMER)' created"; exit 0;; \
			409) echo "WARNING: consumer '$(MAESTRO_CONSUMER)' already exists (race condition)"; exit 0;; \
			*) echo "  Attempt $$i failed (status: $$status), retrying in 5s..."; sleep 5;; \
		esac; \
	done; \
	echo "ERROR: failed to create Maestro consumer after 5 attempts"; exit 1

.PHONY: install-maestro-all
install-maestro-all: install-maestro create-maestro-consumer ## Install Maestro (server + agent + consumer)
	@echo "OK: Maestro installed and consumer created"

.PHONY: uninstall-applied-manifest-crd
uninstall-applied-manifest-crd: check-kubectl ## Uninstall AppliedManifestWorks CRD (for Maestro)
	@echo "Uninstalling AppliedManifestWorks CRD..."
	@kubectl delete -f https://raw.githubusercontent.com/open-cluster-management-io/api/main/work/v1/0000_01_work.open-cluster-management.io_appliedmanifestworks.crd.yaml
	@echo "OK: AppliedManifestWorks CRD uninstalled"

.PHONY: uninstall-maestro
uninstall-maestro: check-helm uninstall-applied-manifest-crd ## Uninstall Maestro
	helm uninstall $(MAESTRO_NAMESPACE)-maestro --namespace $(MAESTRO_NAMESPACE) || true


# ==== RabbitMQ Components ====
.PHONY: generate-rabbitmq-values
generate-rabbitmq-values: ## Generate Helm values for RabbitMQ deployments (HELMFILE_ENV=kind only)
ifeq ($(HELMFILE_ENV),kind)
	./scripts/generate-rabbitmq-values.sh \
		--rabbitmq-url $(RABBITMQ_URL) \
		--namespace $(NAMESPACE)
else
	@echo "OK: generate-rabbitmq-values is not supported for HELMFILE_ENV=$(HELMFILE_ENV)"
endif


# ==== Hyperfleet Targets ====
# add-helm-repo: add a helm repo for a component
# Usage: $(call add-helm-repo,<component-name>,<chart-ref>)
define add-helm-repo
	helm repo add hyperfleet-$(1) "git+https://github.com/$(CHART_ORG)/hyperfleet-$(1)@charts?ref=$(2)&sparse=0"
	helm repo update hyperfleet-$(1)
endef

.PHONY: install-repos
install-repos: check-helmfile-env ## Add all hyperfleet helm repos
	$(call add-helm-repo,api,$(API_CHART_REF))
	$(call add-helm-repo,sentinel,$(SENTINEL_CHART_REF))
	$(call add-helm-repo,adapter,$(ADAPTER_CHART_REF))

.PHONY: install-hyperfleet
install-hyperfleet: check-helmfile-env check-hyperfleet-namespace ## Install all HyperFleet components
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) apply

.PHONY: install-api
install-api: check-helmfile-env ## Install HyperFleet API
	helmfile apply -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) -l component=api

.PHONY: install-sentinels
install-sentinels: check-helmfile-env ## Install Hyperfleet Sentinels
	helmfile apply -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) -l component=sentinel

.PHONY: install-adapters
install-adapters: check-helmfile-env ## Install Hyperfleet Adapters
	helmfile apply -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) -l component=adapter

.PHONY: uninstall-hyperfleet
uninstall-hyperfleet: check-kubectl-context ## Uninstall all HyperFleet components
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) destroy

.PHONY: uninstall-hyperfleet-api
uninstall-hyperfleet-api: check-kubectl-context ## Uninstall Hyperfleet API
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) -l component=api destroy

.PHONY: uninstall-hyperfleet-sentinels
uninstall-hyperfleet-sentinels: check-kubectl-context ## Uninstall Hyperfleet Sentinels
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) -l component=sentinel destroy

.PHONY: uninstall-hyperfleet-adapters
uninstall-hyperfleet-adapters: check-kubectl-context ## Uninstall Hyperfleet Adapters
	helmfile -f helmfile/helmfile.yaml.gotmpl -e $(HELMFILE_ENV) -l component=adapter destroy


# ==== Namespace Cleaner Targets ====
.PHONY: install-cleaner
install-cleaner: check-helm check-kubectl ## Install namespace cleaner CronJob (CLEANER_SCHEDULE, CLEANER_LABEL_SELECTOR, CLEANER_AGE_MINUTES)
	$(call check-namespace,$(CLEANER_NAMESPACE))
	helm upgrade --install namespace-cleaner $(HELM_DIR)/namespace-cleaner \
		--namespace $(CLEANER_NAMESPACE) \
		--set-string "schedule=$(CLEANER_SCHEDULE)" \
		--set-string "labelSelector=$(CLEANER_LABEL_SELECTOR)" \
		--set "ageMinutes=$(CLEANER_AGE_MINUTES)" \
		--set "maestroURL=$(CLEANER_MAESTRO_URL)" \
		--wait
	@echo "OK: namespace cleaner installed in namespace $(CLEANER_NAMESPACE)"

.PHONY: uninstall-cleaner
uninstall-cleaner: check-helm check-kubectl ## Uninstall namespace cleaner CronJob
	helm uninstall namespace-cleaner --namespace $(CLEANER_NAMESPACE) || true
	@echo "OK: namespace cleaner uninstalled"

# ==== Prerequisite/Utility Targets ====
.PHONY: check-helm
check-helm: ## Verify helm and helm-git plugin are installed
	@command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is not installed"; exit 1; }
	@helm plugin list | grep -q "helm-git" || { echo "ERROR: helm-git plugin is not installed. Install with: helm plugin install https://github.com/aslafy-z/helm-git"; exit 1; }
	@echo "OK: helm and helm-git plugin found"

.PHONY: check-helmfile
check-helmfile: check-helm ## Verify helmfile is installed
	@command -v helmfile >/dev/null 2>&1 || { echo "ERROR: helmfile is not installed"; exit 1; }
	@echo "OK: helmfile found"
	@helm diff version >/dev/null 2>&1 || { echo "ERROR: helm diff plugin is not installed. Install with: helm plugin install https://github.com/databus23/helm-diff --verify=false"; exit 1; }
	@echo "OK: helm diff plugin found"

.PHONY: check-kind
check-kind: ## Verify kind is installed
	@command -v kind >/dev/null 2>&1 || { echo "ERROR: kind is not installed"; exit 1; }
	@echo "OK: kind found"

.PHONY: check-kubectl
check-kubectl: ## Verify kubectl is installed and context is set
	@command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is not installed"; exit 1; }
	@kubectl config current-context >/dev/null 2>&1 || { echo "ERROR: no kubectl context set"; exit 1; }
	@echo "OK: kubectl found, context: $$(kubectl config current-context)"

.PHONY: check-jq
check-jq: ## Verify jq is installed
	@command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is not installed. Install with: brew install jq"; exit 1; }
	@echo "OK: jq found"

.PHONY: check-helmfile-env
check-helmfile-env: check-helmfile check-kubectl-context check-helmfile-env-generated ## Verify kubectl context and generated values directory exists

.PHONY: check-helmfile-env-generated
check-helmfile-env-generated: ## Check that the generated directory exists based on HELMFILE_ENV
	@if [ "$(HELMFILE_ENV)" = "gcp" ]; then \
		test -d $(GENERATED_DIR) || { echo "ERROR: generated-values-from-terraform directory does not exist"; exit 1; }; \
		echo "OK: generated-values-from-terraform directory exists"; \
	elif [ "$(HELMFILE_ENV)" = "kind" ]; then \
		test -d $(GENERATED_RABBITMQ_DIR) || { echo "ERROR: generated-values-rabbitmq directory does not exist"; exit 1; }; \
		echo "OK: generated-values-rabbitmq directory exists"; \
	fi
	@echo "OK: Did not need to validate generated values for environment: $(HELMFILE_ENV)"

.PHONY: check-kubectl-context
check-kubectl-context: check-kubectl ## Verify kubectl context matches HELMFILE_ENV for kind and e2e-kind
	@if [ "$(HELMFILE_ENV)" = "kind" ] || [ "$(HELMFILE_ENV)" = "e2e-kind" ]; then \
		if ! kubectl config current-context | grep -q "kind-"; then \
			echo "ERROR: HELMFILE_ENV=$(HELMFILE_ENV) requires kind context"; \
			exit 1; \
		fi; \
		echo "OK: kubectl context matches HELMFILE_ENV=$(HELMFILE_ENV)"; \
	fi;

.PHONY: check-terraform
check-terraform: ## Verify terraform is installed
	@command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform is not installed"; exit 1; }
	@echo "OK: terraform found"

.PHONY: check-tf-files
check-tf-files: ## Verify terraform env files exist
	@test -f $(TF_DIR)/$(TF_BACKEND) || { echo "ERROR: backend file not found: $(TF_DIR)/$(TF_BACKEND)";  echo "Create a copy from $(TF_DIR)/$(TF_BACKEND).example and customize it"; exit 1; }
	@test -f $(TF_DIR)/$(TF_VARS) || { echo "ERROR: tfvars file not found: $(TF_DIR)/$(TF_VARS)";  echo "Create a copy from $(TF_DIR)/$(TF_VARS).example and customize it"; exit 1; }
	@echo "OK: terraform env files found for $(TF_ENV)"

# check-namespace: check if a namespace exists and create it if it doesn't
# Usage: $(call check-namespace,<namespace-name>)
define check-namespace
	@kubectl get namespace $(1) >/dev/null 2>&1 || kubectl create namespace $(1) || { echo "ERROR: failed to create namespace $(1)"; exit 1; }
	@echo "OK: namespace $(1) ready"
endef

.PHONY: check-hyperfleet-namespace
check-hyperfleet-namespace: ## Create Hyperfleet namespace if it doesn't exist and label it
	@printf '%s' "$(NAMESPACE)" | grep -qE '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$$' \
		|| { echo "ERROR: NAMESPACE '$(NAMESPACE)' is not a valid DNS label (lowercase alphanumeric and hyphens, 1-63 chars)"; exit 1; }
	$(call check-namespace,$(NAMESPACE))
	@kubectl label namespace "$(NAMESPACE)" "hyperfleet.io/test-run=$(NAMESPACE)" --overwrite >/dev/null
	@echo "OK: namespace $(NAMESPACE) labeled with hyperfleet.io/test-run=$(NAMESPACE)"

.PHONY: check-maestro-namespace
check-maestro-namespace: ## Create Maestro namespace if it doesn't exist
	$(call check-namespace,$(MAESTRO_NAMESPACE))

.PHONY: check-gke-context
check-gke-context: check-kubectl ## Verify kubectl context points to GKE cluster
	@CONTEXT=$$(kubectl config current-context); \
	if echo "$$CONTEXT" | grep -q "gke_"; then \
		echo "OK: connected to GKE cluster (context: $$CONTEXT)"; \
	else \
		echo "WARNING: current context '$$CONTEXT' does not appear to be a GKE cluster"; \
		echo "         Expected context name containing 'gke_'"; \
		echo "         Continuing anyway, but verify your cluster is correct"; \
	fi

.PHONY: clean-generated
clean-generated: ## Remove generated dir
	rm -rf $(GENERATED_DIR)
	rm -rf $(GENERATED_RABBITMQ_DIR)
	@echo "OK: cleaned generated terraform values"

.PHONY: helm-deps
helm-deps: check-helm ## Run helm dependency update for all charts
	@for chart in $(HELM_DIR)/*/; do \
		echo "Updating dependencies for $$chart..."; \
		helm dependency update "$$chart"; \
	done

.PHONY: status
status: check-kubectl check-helmfile-env ## Show helm releases and pod status
	@echo "=== Helm Releases ==="
	@helm list --namespace $(NAMESPACE) 2>/dev/null || true
	@helm list --namespace $(MAESTRO_NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "=== Pods ==="
	@kubectl get pods --namespace $(NAMESPACE) 2>/dev/null || true
	@kubectl get pods --namespace $(MAESTRO_NAMESPACE) 2>/dev/null || true

.PHONY: help
help: ## Show this help message
	@echo "HyperFleet Infrastructure - Available Make Targets"
	@echo ""
	@echo "Usage: make [target] [VARIABLE=value ...]"
	@echo ""
	@echo "Environment: HELMFILE_ENV=$(HELMFILE_ENV) (gcp|kind|e2e-gcp|e2e-kind)"
	@echo ""
	@awk '/^# ====/ { \
		section = $$0; \
		sub(/^# ==== /, "", section); \
		sub(/ ====$$/,"", section); \
		next; \
	} \
	/^[a-zA-Z_-]+:.*?## / { \
		if (section) { \
			if (!(section in seen)) { \
				if (count > 0) print ""; \
				printf "\033[1m%s:\033[0m\n", section; \
				seen[section] = 1; \
				count++; \
			} \
			split($$0, parts, ":"); \
			target = parts[1]; \
			sub(/.*## /, "", $$0); \
			printf "  \033[36m%-35s\033[0m %s\n", target, $$0; \
		} \
	}' $(MAKEFILE_LIST)



# ==== CI Targets ====
# ci-dry-run: validation on terraform and helm plugins and maestro helm chart
# ci-test: Run terraform install + maestro install + health check on maestro
# ci-cleanup: Uninstall maestro and destroy terraform resources

# TODO: HYPERFLEET-1067 - Will add more complete helmfile linting and validation
# Currently only linting, validating and installing via terrafrom and installing the maestro chart


# CI-DRY-RUN
.PHONY: validate-terraform
validate-terraform: check-terraform ## Validate Terraform syntax and formatting
	cd $(TF_DIR) && \
	terraform init -backend=false && \
	terraform fmt -check -recursive -diff && \
	terraform validate

.PHONY: lint-helm
lint-helm: check-helm helm-deps ## Lint all Helm charts
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
.PHONY: validate-maestro
validate-maestro: check-helm ## Validate Maestro Helm chart rendering
	helm dependency update $(HELM_DIR)/maestro
	@echo "Validating maestro chart..."
	helm template $(MAESTRO_NAMESPACE)-maestro $(HELM_DIR)/maestro \
		--set agent.messageBroker.mqtt.host=maestro-mqtt.$(MAESTRO_NAMESPACE) > /dev/null
	@echo "OK: all Helm charts rendered successfully"

.PHONY: ci-validate
ci-validate: validate-terraform lint-helm lint-shellcheck ## Ci validate: validate terraform + lint helm + lint shellcheck

.PHONY: ci-dry-run
ci-dry-run: ci-validate ## Ci dry-run: ci-validate + validate maestro
	$(MAKE) validate-maestro

.PHONY: health-check-maestro
health-check-maestro: check-kubectl ## Verify Maestro Components
	@echo "Checking Maestro components..."
	@deploys=$$(kubectl get deployments --namespace $(MAESTRO_NAMESPACE) --kubeconfig $(KUBECONFIG) -o name) && \
		[ -n "$$deploys" ] || { echo "ERROR: no deployments found in namespace $(MAESTRO_NAMESPACE)"; exit 1; }; \
		for deploy in $$deploys; do \
			echo "  Waiting for $$deploy..."; \
			kubectl rollout status $$deploy --namespace $(MAESTRO_NAMESPACE) --kubeconfig $(KUBECONFIG) --timeout=300s || exit 1; \
		done
	@echo "OK: all components healthy"

.PHONY: ci-test
ci-test: install-terraform get-credentials install-priority-classes install-maestro create-maestro-consumer health-check-maestro ## Ci test: install terraform + get credentials + install maestro + create maestro consumer + health check maestro

# CI-CLEANUP
.PHONY: ci-cleanup
ci-cleanup: uninstall-maestro destroy-terraform ## Ci cleanup: uninstall maestro + destroy terraform

# ==== Full Deployment Targets ====
# Kind targets

.PHONY: local-up-kind
local-up-kind: create-kind-cluster kind-build-images install-priority-classes install-maestro-all generate-rabbitmq-values install-hyperfleet ## Full local kind setup (cluster + images + maestro + hyperfleet)

.PHONY: local-down-kind
local-down-kind: uninstall-hyperfleet uninstall-maestro delete-kind-cluster ## Tear down kind: uninstall all + delete cluster

# GKE targets
.PHONY: local-up-gcp
local-up-gcp: install-terraform get-credentials install-priority-classes install-maestro-all install-hyperfleet ## Full gke setup (cluster + maestro + hyperfleet)

.PHONY: local-down-gcp
local-down-gcp: get-credentials uninstall-maestro uninstall-hyperfleet destroy-terraform ## Tear down gke: (cluster + maestro + hyperfleet)
