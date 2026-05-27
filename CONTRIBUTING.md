# Contributing to HyperFleet Infrastructure

## Development Setup

No build/compile steps. You need the right tools to work with Terraform, Helm, and Kubernetes.

```bash
# 1. Clone the repository
git clone https://github.com/openshift-hyperfleet/hyperfleet-infra.git
cd hyperfleet-infra

# 2. Install prerequisites
#    - helm + helm-git plugin + helmfile
#    - kubectl
#    - terraform 1.13.1 via asdf (GCP only)
#    - Google Cloud SDK + gke-gcloud-auth-plugin (GCP only)

# 3. Verify prerequisites
make check-helm
make check-helmfile
make check-kubectl
make check-kind # kind only
make check-terraform   # GCP only

# 4. For GCP: set up personal Terraform config files
cp terraform/envs/gke/dev.tfvars.example terraform/envs/gke/dev-<username>.tfvars
cp terraform/envs/gke/dev.tfbackend.example terraform/envs/gke/dev-<username>.tfbackend
# Set developer_name = "<username>" in tfvars
# Set prefix = "terraform/state/dev-<username>" in tfbackend

# 5. For GCP: authenticate
gcloud auth application-default login
gcloud config set project hcm-hyperfleet
```

Notes:
- Personal tfvars/tfbackend are gitignored — never commit them
- For kind deployments, Terraform setup is not required
- `NAMESPACE` controls which Kubernetes namespace is used; set it to run parallel deployments on the same cluster
- `helm-git` plugin is required for helm to pull charts from sibling repos
- `diff` plugin is required for helmfile to show the change on upgrade

## Environment Configuration Files

The Makefile auto-sources one of two env files based on `HELMFILE_ENV`:
- HELMFILE_ENV=gcp and HELMFILE_ENV=e2e-gcp → sources `env.gcp`
- HELMFILE_ENV=kind and HELMFILE_ENV=e2e-kind → sources `env.kind`

All variables use `?=`. CLI overrides always win:

Example:
```bash
HELMFILE_ENV=kind NAMESPACE=my-namespace REGISTRY=quay.io make install-hyperfleet
```

Configuration precedence (highest to lowest):
1. CLI variables
2. `env.gcp` or `env.kind`
3. Makefile defaults

## Repository Structure

```
hyperfleet-infra/
├── Makefile                         # Entry point — run 'make help'
├── env.gcp                          # GCP defaults (Google Pub/Sub, LoadBalancer)
├── env.kind                         # kind defaults (RabbitMQ, ClusterIP)
├── helmfile/
│   ├── helmfile.yaml.gotmpl         # Helmfile orchestration
│   ├── environments/                # Per-env configs (gcp, kind, e2e-gcp, e2e-kind)
│   ├── configs/
│   │   ├── base/adapters/           # Adapter configs (adapter1, adapter2, adapter3)
│   │   └── e2e/adapters/            # E2E adapter configs
│   └── values/                      # Helm value templates
├── helm/
│   ├── maestro/                     # Maestro server + agent (umbrella chart)
│   └── rabbitmq/                    # Dev-only RabbitMQ chart
├── scripts/
│   ├── generate-rabbitmq-values.sh  # Generates RabbitMQ broker config
│   └── kind-build-images.sh         # Builds and loads images into kind
├── terraform/
│   ├── README.md                    # Detailed Terraform documentation
│   ├── main.tf                      # Root module (GKE cluster, Pub/Sub, firewall)
│   ├── helm-values-files.tf         # Writes generated Helm values via local_file
│   ├── bootstrap/                   # One-time GCP setup scripts (admin only)
│   ├── shared/                      # Shared VPC infrastructure (deploy once)
│   ├── modules/
│   │   ├── cluster/gke/             # GKE cluster module
│   │   └── pubsub/                  # Google Pub/Sub module
│   └── envs/gke/                    # Per-developer tfvars and tfbackend files
├── generated-values-from-terraform/ # Auto-generated, gitignored
├── generated-values-rabbitmq/       # Auto-generated, gitignored
├── README.md
├── CONTRIBUTING.md
├── AGENTS.md
└── CHANGELOG.md
```

## Validation and Testing

Run these before opening a PR:

### CI Validation
```bash
make ci-validate     # terraform fmt+validate + lint checks
make ci-dry-run      # ci-validate + maestro chart validation
```

Individual checks:

```bash
make validate-terraform            # terraform init (no backend) + fmt check + validate
make validate-maestro              # templates maestro charts
make lint-helm                     # helm lint all charts under helm/*/
make lint-shellcheck               # shellcheck all *.sh
HELMFILE_ENV=<env> make lint-helmfile
HELMFILE_ENV=<env> make template-helmfile   # dry-run render for one env
```

## Common Development Tasks

### Kind Deployment (local development)

```bash
export HELMFILE_ENV=kind
export NAMESPACE=hyperfleet-local

# Step by step installation
make create-kind-cluster
make install-maestro-all
make generate-rabbitmq-values
make kind-build-images
make install-hyperfleet

# One-shot installation (image builds by default - BUILD_IMAGES set in env.kind)
make local-up-kind
```

### E2E Tests on Kind

#### Port-forwarding required for E2E tests:

```bash
export NAMESPACE=<e2e_namespace>
kubectl port-forward -n maestro svc/maestro 8001:8000 &
kubectl port-forward -n $NAMESPACE svc/hyperfleet-api 8000:8000 &
export MAESTRO_URL=http://localhost:8001
export HYPERFLEET_API_URL=http://localhost:8000
```

#### Run tests

```bash
# Run tier0 tests
cd ../hyperfleet-e2e && make generate && make build && ./bin/hyperfleet-e2e test --label-filter=tier0
```


### GKE Deployment (GCP)

```bash
export HELMFILE_ENV=gcp
export NAMESPACE=hyperfleet

# Step by step installation
make install-terraform
make get-credentials
make install-maestro-all
make install-hyperfleet

# One-shot installation
make local-up-gcp
```

### E2E Tests on GKE

#### Required Variables for E2E tests:
```bash
kubectl patch svc maestro -n maestro -p '{"spec":{"type":"LoadBalancer"}}'
export MAESTRO_EXTERNAL_IP=$(kubectl get svc maestro -n maestro -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export MAESTRO_URL=http://${MAESTRO_EXTERNAL_IP}:8000
export API_EXTERNAL_IP=$(kubectl get svc hyperfleet-api -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export HYPERFLEET_API_URL=http://${API_EXTERNAL_IP}:8000
```

#### Run tests

```bash
# Run tier0 tests
cd ../hyperfleet-e2e && make generate && make build && ./bin/hyperfleet-e2e test --label-filter=tier0
```

## Customization

### Using custom images

- CLI Overrides for specific variables
- Update env.* files with custom values
```bash
# CLI Overrides
REGISTRY=quay.io/$USER API_IMAGE_TAG=v0.2.0 HELMFILE_ENV=gcp make install-hyperfleet

API_IMAGE_TAG=dev-abc123 HELMFILE_ENV=kind make install-api
```

### Building and loading images into kind

```bash
export HELMFILE_ENV=<env> # verify that BUILD_IMAGES ?= true in env.kind
make kind-build-images

# or CLI override
BUILD_IMAGES=true make kind-build-images

# or call the script directly:
PROJECTS_DIR=~/Code/openshift-hyperfleet REGISTRY=localhost ./scripts/kind-build-images.sh
```

## Cleanup

### kind / e2e-kind

```bash
export HELMFILE_ENV=kind # or HELMFILE_ENV=e2e-kind
export NAMESPACE=<namespace>

# for individual targets
make uninstall-hyperfleet
make uninstall-maestro
make delete-kind-cluster

# for full teardown
make local-down-kind
```

### gcp / e2e-gcp

```bash
export HELMFILE_ENV=gcp # or HELMFILE_ENV=e2e-gcp
export NAMESPACE=<namespace>

# for individual targets
make uninstall-hyperfleet
make uninstall-maestro
make destroy-terraform

# for full teardown
make local-down-gcp
```

## Commit Standards

Format: `HYPERFLEET-XXX - <type>: <subject>`

Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`

Examples:
- `HYPERFLEET-761 - docs: add CONTRIBUTING.md`
- `HYPERFLEET-123 - feat: add support for custom Helm chart refs`
- `HYPERFLEET-456 - fix: correct RabbitMQ URL format in generated values`

Full standard: https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/commit-standard.md

## Release Process

No semantic versioning. Infrastructure changes deploy from `main` after review and approval via `OWNERS` (Prow enforced).

- Helm charts live in component repos (`hyperfleet-api`, `hyperfleet-sentinel`, `hyperfleet-adapter`) and are pulled via helm-git at deploy time
- Terraform modules are versioned through git tags
- Image tags default to `latest` (GCP) or `local` (kind); override with `API_IMAGE_TAG`, `SENTINEL_IMAGE_TAG`, `ADAPTER_IMAGE_TAG`
