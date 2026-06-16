# HyperFleet Infrastructure

Infrastructure as Code for HyperFleet development environments using **Makefile + Helmfile + Terraform**.

`make help` is the canonical entry point.

## Overview

Two message broker backends are supported:

- **Google Pub/Sub** (default) — managed by GCP, provisioned via Terraform
- **RabbitMQ** — self-hosted via `helm/rabbitmq/`, used for kind/local deployments

**Terraform manages (GCP only):**
- Shared VPC, subnets, firewall rules (one-time per project)
- Per-developer GKE clusters
- Google Pub/Sub topics, subscriptions, Workload Identity
- Helm values files written to `generated-values-from-terraform/`

**Helmfile manages:**
- All HyperFleet components (API, Sentinels, Adapters, *RabbitMQ)
- Environment-specific configurations across four environments

## Prerequisites

### All environments

- `helm` + [`helm-git` plugin](https://github.com/aslafy-z/helm-git) + [`helm-diff` plugin](https://github.com/databus23/helm-diff)
- `helmfile`
- `kubectl` with a configured context

```bash
helm plugin install https://github.com/aslafy-z/helm-git
helm plugin install https://github.com/databus23/helm-diff --verify=false
```

### GCP only

- `terraform 1.13.1` (pinned via `.tool-versions`; use [asdf](https://asdf-vm.com/))
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) + `gke-gcloud-auth-plugin`
- Access to the `hcm-hyperfleet` GCP project

### kind only

- `kind`
- `podman` or `docker` (for image builds)

## Deployment Environments

| `HELMFILE_ENV` | Cluster | Broker | Notes |
|----------------|---------|--------|-------|
| `gcp` | GKE (Terraform) | Google Pub/Sub | Requires Terraform-generated values |
| `kind` | kind (local) | RabbitMQ | Requires script-generated values |
| `e2e-gcp` | GKE (Terraform) | Google Pub/Sub | Broker config hardcoded in helmfile |
| `e2e-kind` | kind (local) | RabbitMQ | Broker config hardcoded in helmfile |

`HELMFILE_ENV` defaults to `gcp` if not set.

### Environment variable loading

The Makefile selects the env file based on `HELMFILE_ENV`:
- contains `gcp` → sources `env.gcp`
- does not contain `gcp` → sources `env.kind` (so `kind`, `e2e-kind`, etc.)

All variables use `?=`. CLI overrides always win:

```bash
HELMFILE_ENV=kind NAMESPACE=my-namespace REGISTRY=quay.io make install-hyperfleet
```

Configuration precedence (highest to lowest):
1. CLI variables
2. `env.gcp` or `env.kind`
3. Makefile defaults

## Makefile Targets

### HyperFleet

| Target | Description |
|--------|-------------|
| `make install-hyperfleet` | Install all HyperFleet components |
| `make install-api` | Install HyperFleet API only |
| `make install-sentinels` | Install Sentinels only |
| `make install-adapters` | Install Adapters only |
| `make uninstall-hyperfleet` | Uninstall all HyperFleet components |
| `make uninstall-hyperfleet-api` | Uninstall API only |
| `make uninstall-hyperfleet-sentinels` | Uninstall Sentinels only |
| `make uninstall-hyperfleet-adapters` | Uninstall Adapters only |

### Terraform

| Target | Description |
|--------|-------------|
| `make install-terraform` | `terraform init` + `apply`; writes generated values |
| `make plan-terraform` | `terraform plan` (no apply) |
| `make validate-terraform` | `terraform init -backend=false` + fmt check + validate |
| `make get-credentials` | Configure kubectl from terraform output |
| `make destroy-terraform` | Destroy Terraform-managed infrastructure |

### Maestro

| Target | Description |
|--------|-------------|
| `make install-maestro` | Install Maestro server + agent (runs `helm dependency update` first) |
| `make create-maestro-consumer` | Create a Maestro consumer (requires Maestro running) |
| `make install-maestro-all` | `install-maestro` + `create-maestro-consumer` |
| `make uninstall-maestro` | Uninstall Maestro |

### kind

| Target | Description |
|--------|-------------|
| `make create-kind-cluster` | Create kind cluster or export kubeconfig if it exists |
| `make delete-kind-cluster` | Delete the kind cluster |
| `make kind-build-images` | Build and load component images into kind |
| `make local-up-kind` | Full local setup: cluster + images + maestro + values + deploy |
| `make local-down-kind` | Tear down: uninstall hyperfleet + maestro + delete cluster |

### Generated values

| Target | Description |
|--------|-------------|
| `make generate-rabbitmq-values` | Generate RabbitMQ broker Helm values (`HELMFILE_ENV=kind` only) |
| `make clean-generated` | Remove all generated value directories |

### Validation / CI

| Target | Description |
|--------|-------------|
| `make ci-dry-run` | `ci-validate` + `validate maestro` |
| `make ci-test` | `install terraform` + `get-credentials` + `install-maestro` + `create-maestro-consumer` + `health-check-maestro` |
| `make ci-cleanup` | `uninstall-maestro` + `destroy-terraform` |


## Variables

| Variable | GCP default | kind default | Notes |
|----------|------------|--------------|-------|
| `HELMFILE_ENV` | `gcp` | `kind` | Also `e2e-gcp`, `e2e-kind` |
| `NAMESPACE` | `hyperfleet` | `hyperfleet-local` | e2e envs use `hyperfleet-e2e[-$USER]` |
| `MAESTRO_NAMESPACE` | `maestro` | `maestro` | |
| `REGISTRY` | `quay.io` | `localhost` | |
| `API_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api` | `hyperfleet-api` | |
| `SENTINEL_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-sentinel` | `hyperfleet-sentinel` | |
| `ADAPTER_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-adapter` | `hyperfleet-adapter` | |
| `API_IMAGE_TAG` | `dev` | `local` | |
| `SENTINEL_IMAGE_TAG` | `dev` | `local` | |
| `ADAPTER_IMAGE_TAG` | `dev` | `local` | |
| `IMAGE_PULL_POLICY` | `Always` | `IfNotPresent` | |
| `CHART_ORG` | `openshift-hyperfleet` | `openshift-hyperfleet` | GitHub org for helm-git chart repos |
| `API_CHART_REF` | `main` | `main` | Git ref for API chart |
| `SENTINEL_CHART_REF` | `main` | `main` | Git ref for Sentinel chart |
| `ADAPTER_CHART_REF` | `main` | `main` | Git ref for Adapter chart |
| `TF_ENV` | `dev` | N/A | Selects `envs/gke/<TF_ENV>.tfvars` |
| `RABBITMQ_URL` | N/A | `amqp://guest:guest@rabbitmq:5672` | |
| `MAESTRO_CONSUMER` | `cluster1` | `cluster1` | |
| `KIND_CLUSTER_NAME` | N/A | `kind` | |
| `PROJECTS_DIR` | N/A | `~/openshift-hyperfleet` | Parent dir for sibling repos (image builds) |
| BUILD_IMAGES | N/A | true | Set to false to skip image builds |

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
│   └── values/                      # Helm value templates (.gotmpl)
├── helm/
│   ├── maestro/                     # Maestro umbrella chart (deps via helm-git)
│   └── rabbitmq/                    # Dev-only RabbitMQ (not production-ready)
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
└── generated-values-rabbitmq/       # Auto-generated, gitignored
```

## Generated Helm Values

Both generated directories are gitignored and must exist before `make install-hyperfleet`.

| Env | How generated | Directory |
|-----|---------------|-----------|
| `gcp` | `make install-terraform` (Terraform `local_file`) | `generated-values-from-terraform/` |
| `kind` | `make generate-rabbitmq-values` (shell script) | `generated-values-rabbitmq/` |
| `e2e-gcp` / `e2e-kind` | Not needed — hardcoded in helmfile | — |

Files written per component:

| File | Component |
|------|-----------|
| `sentinel-clusters.yaml` | Sentinel (cluster events) |
| `sentinel-nodepools.yaml` | Sentinel (nodepool events) |
| `adapter1.yaml` | Adapter 1 |
| `adapter2.yaml` | Adapter 2 |
| `adapter3.yaml` | Adapter 3 |

## Shared Infrastructure (one-time admin setup)

The shared VPC must be deployed once before any developer clusters. This is an admin-only operation:

```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
terraform apply
```

See [terraform/shared/README.md](terraform/shared/README.md) for details.

## Related Repositories

- [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) — API server
- [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) — Sentinel
- [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) — Adapter Framework
- [architecture](https://github.com/openshift-hyperfleet/architecture) — System architecture and standards

## License

Apache License 2.0
