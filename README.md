# HyperFleet Infrastructure

Infrastructure as Code for HyperFleet development environments.

## Overview

This repository provides a `Makefile`-driven workflow for provisioning infrastructure (Terraform) and deploying HyperFleet components (Helm). Terraform manages cloud resources (GKE clusters, Pub/Sub); Helm charts handle all application deployments.

**What Terraform manages:**

- **Shared infrastructure** (VPC, subnets, firewall rules) - deployed once per GCP project
- **Developer GKE clusters** - personal Kubernetes clusters for each developer
- **Google Pub/Sub** (optional) - managed message broker with Workload Identity

**What Helm manages (via Makefile):**

- HyperFleet API, Sentinels, Adapters
- Maestro (server + agent)

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- [Helm](https://helm.sh/docs/intro/install/) + [helm-git plugin](https://github.com/aslafy-z/helm-git) (`helm plugin install https://github.com/aslafy-z/helm-git`)
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) + `gke-gcloud-auth-plugin`
- `kubectl`
- Access to the `hcm-hyperfleet` GCP project

## Quick Start

### 1. One-time setup

```bash
# Authenticate with GCP
gcloud auth application-default login
gcloud config set project hcm-hyperfleet

# Create your Terraform config files
cp terraform/envs/gke/dev.tfvars.example terraform/envs/gke/dev.tfvars
cp terraform/envs/gke/dev.tfbackend.example terraform/envs/gke/dev.tfbackend
# Edit both files: set developer_name and prefix to your username
```

### 2. Install everything

```bash
# Provision cluster + deploy all HyperFleet components
make install-all

# if using custom registry for hyperfleet images
make install-all REGISTRY=quay.io/<your username>

# Deploy a specific image version
make install-all IMAGE_TAG=v0.2.0

# Deploy with different tags per component
make install-all IMAGE_TAG=v0.2.0 API_TAG=v0.3.0
```

> **Note:** Helm release names are prefixed with the namespace (e.g. `hyperfleet-api`, `hyperfleet-adapter1`) to avoid ClusterRole collisions when multiple deployments share the same cluster. Use a different `NAMESPACE` for each deployment.

This runs the following steps in order:

```
install-terraform       → Create GKE cluster and cloud resources
get-credentials         → Configure kubectl from Terraform outputs
tf-helm-values          → Generate Helm override values (Pub/Sub config, etc.)
install-hyperfleet      → Deploy API, Sentinels, and Adapters via Helm
install-maestro         → Deploy Maestro server + agent
create-maestro-consumer → Register a Maestro consumer
```

### 4. Verify

```bash
make status
```

## Installation Targets

Run `make help` to see all targets. Key targets:

| Target | Description |
|--------|-------------|
| `make install-all` | Full install: Terraform + credentials + Helm values + HyperFleet + Maestro |
| `make install-terraform` | Provision cloud infrastructure only |
| `make get-credentials` | Configure kubectl from Terraform outputs |
| `make tf-helm-values` | Generate Helm override values from Terraform outputs |
| `make install-hyperfleet` | Deploy API + Sentinels + Adapters (requires cluster credentials) |
| `make install-maestro` | Deploy Maestro server + agent (separate namespace) |
| `make create-maestro-consumer` | Register a Maestro consumer (requires Maestro running) |
| `make install-api` | Deploy HyperFleet API only |
| `make install-sentinels` | Deploy all Sentinels |
| `make install-adapters` | Deploy all Adapters |
| `make uninstall-all` | Remove all Helm releases |
| `make status` | Show Helm releases and pod status |

### Makefile Variables

Override with `VAR=value`, e.g. `make install-all TF_ENV=dev-alice`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_ENV` | `dev` | Terraform environment (selects `envs/gke/<TF_ENV>.tfvars` and `.tfbackend`) |
| `NAMESPACE` | `hyperfleet` | Kubernetes namespace for HyperFleet components |
| `MAESTRO_NS` | `maestro` | Kubernetes namespace for Maestro |
| `BROKER_TYPE` | `googlepubsub` | Message broker type |
| `REGISTRY` | `quay.io/openshift-hyperfleet` | Override image registry for API, Sentinels, and Adapters (e.g. `quay.io/myuser`) |
| `IMAGE_TAG` | `v0.1.0` | Default image tag for all components (API, Sentinels, Adapters) |
| `API_TAG` | `IMAGE_TAG` | Override image tag for the API only |
| `SENTINEL_TAG` | `IMAGE_TAG` | Override image tag for Sentinels only |
| `ADAPTER_TAG` | `IMAGE_TAG` | Override image tag for Adapters only |
| `MAESTRO_CONSUMER` | `cluster1` | Maestro consumer name for `create-maestro-consumer` |

## Repository Structure

```
hyperfleet-infra/
├── Makefile                    # Main entry point (make help)
├── scripts/
│   └── tf-helm-values.sh      # Generates Helm values from Terraform outputs
├── helm/                      # Helm charts for application components
│   ├── api/                   # HyperFleet API
│   ├── sentinel-clusters/     # Sentinel for cluster events
│   ├── sentinel-nodepools/    # Sentinel for nodepool events
│   ├── adapter1/              # Adapter 1
│   ├── adapter2/              # Adapter 2
│   ├── adapter3/              # Adapter 3
│   └── maestro/               # Maestro server + agent
├── terraform/
│   ├── README.md              # Detailed Terraform documentation
│   ├── main.tf                # Root module (GKE cluster, Pub/Sub, firewall)
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── versions.tf
│   ├── backend.tf
│   ├── bootstrap/             # One-time setup scripts
│   ├── shared/                # Shared infrastructure (deploy once per project)
│   ├── modules/
│   │   ├── cluster/gke/       # GKE cluster module
│   │   └── pubsub/            # Google Pub/Sub module
│   └── envs/gke/              # Per-environment tfvars and tfbackend files
└── generated-values-from-terraform/  # Auto-generated Helm values (gitignored)
```

### Generated Helm Values

The `generated-values-from-terraform/` directory bridges Terraform and Helm. When Terraform creates cloud resources like Pub/Sub topics and subscriptions, the resulting resource names and project IDs need to be passed to Helm charts at install time.

Running `make tf-helm-values` (or `make install-all`, which includes it) executes `scripts/tf-helm-values.sh`, which reads Terraform outputs and generates per-component YAML files:

| Generated File | Used By | Contents |
|----------------|---------|----------|
| `sentinel-clusters.yaml` | `install-sentinel-clusters` | Pub/Sub topic name and project ID for cluster events |
| `sentinel-nodepools.yaml` | `install-sentinel-nodepools` | Pub/Sub topic name and project ID for nodepool events |
| `adapter1.yaml` | `install-adapter1` | Pub/Sub subscription ID, topic, and project ID |
| `adapter2.yaml` | `install-adapter2` | Pub/Sub subscription ID, topic, and project ID |
| `adapter3.yaml` | `install-adapter3` | Pub/Sub subscription ID, topic, and project ID |

Each install target conditionally passes its generated file via `--values` if it exists. If Pub/Sub is not enabled (no generated files), the charts fall back to their built-in defaults.

To regenerate after a Terraform change: `make tf-helm-values`. To clean up: `make clean-generated`.

## Shared Infrastructure (One-time Admin Setup)

The shared VPC must be deployed once before any developer clusters:

```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
terraform apply
```

See [terraform/shared/README.md](terraform/shared/README.md) for details.

## Destroying Resources

```bash
# Uninstall all Helm releases
make uninstall-all

# Destroy Terraform-managed infrastructure
cd terraform && terraform destroy -var-file=envs/gke/dev.tfvars
```

## Related Repositories

- [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) - HyperFleet API server
- [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) - HyperFleet Sentinel
- [adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) -  HyperFleet Adapter Framework
- [hyperfleet-chart](https://github.com/openshift-hyperfleet/hyperfleet-chart) - Helm charts (base + cloud overlays)

## License

Apache License 2.0
