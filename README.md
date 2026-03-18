# HyperFleet Infrastructure

Infrastructure as Code for HyperFleet development environments.

## Overview

This repository provides a `Makefile`-driven workflow for provisioning infrastructure (Terraform) and deploying HyperFleet components (Helm).

HyperFleet supports two message broker backends:

- **Google Pub/Sub** (default) — managed by GCP, provisioned via Terraform. Best for GCP-based deployments.
- **RabbitMQ** — self-hosted, must be installed separately. Works on any Kubernetes cluster.

**What Terraform manages (GCP only):**

- **Shared infrastructure** (VPC, subnets, firewall rules) - deployed once per GCP project
- **Developer GKE clusters** - personal Kubernetes clusters for each developer
- **Google Pub/Sub** (optional) - managed message broker with Workload Identity

**What Helm manages (via Makefile):**

- HyperFleet API, Sentinels, Adapters
- Maestro (server + agent)

## Prerequisites

### Common

- [Helm](https://helm.sh/docs/intro/install/) + [helm-git plugin](https://github.com/aslafy-z/helm-git) (`helm plugin install https://github.com/aslafy-z/helm-git`)
- `kubectl` configured with access to your target cluster

### Google Pub/Sub deployments

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) + `gke-gcloud-auth-plugin`
- Access to the `hcm-hyperfleet` GCP project

### RabbitMQ deployments

- A RabbitMQ instance accessible from the cluster. For development, use `make install-rabbitmq` (included in this repo). For production, provide your own RabbitMQ installation.

## Quick Start (Google Pub/Sub)

This is the default deployment path using GCP infrastructure and Google Pub/Sub as the message broker.

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

# With custom registry
make install-all REGISTRY=quay.io/<your username>

# With specific image version
make install-all IMAGE_TAG=v0.2.0
```

> **Note:** Helm release names are prefixed with the namespace (e.g. `hyperfleet-api`, `hyperfleet-adapter1`) to avoid ClusterRole collisions when multiple deployments share the same cluster. Use a different `NAMESPACE` for each deployment.

`make install-all` runs these steps in order:

```text
install-terraform       → Create GKE cluster and cloud resources
get-credentials         → Configure kubectl from Terraform outputs
tf-helm-values          → Generate Helm override values (Pub/Sub config)
install-maestro         → Deploy Maestro server + agent
create-maestro-consumer → Register a Maestro consumer
install-hyperfleet      → Deploy API, Sentinels, and Adapters via Helm
```

### 3. Verify

```bash
make status
```

## Deploying with RabbitMQ

Use this path when deploying on any Kubernetes cluster with RabbitMQ as the message broker. Terraform is not required.

### Quick install

```bash
make install-all-rabbitmq
```

This single command installs RabbitMQ, generates broker config, deploys all HyperFleet components, and sets up Maestro.

> **Development only:** The included RabbitMQ manifest uses hardcoded credentials (`guest:guest`) and no persistent storage. For shared or staging environments, use a Kubernetes Secret for credentials and a StatefulSet with PersistentVolumeClaim for data durability.

### Verify

```bash
make status
```

## Installation Targets

Run `make help` to see all targets. Key targets:

| Target | Description |
|--------|-------------|
| `make install-all` | Full GCP install: Terraform + credentials + Helm values + HyperFleet + Maestro |
| `make install-all-rabbitmq` | Full RabbitMQ install: RabbitMQ + Helm values + HyperFleet + Maestro (no Terraform) |
| `make install-terraform` | Provision GCP cloud infrastructure only |
| `make get-credentials` | Configure kubectl from Terraform outputs |
| `make tf-helm-values` | Generate Helm override values (broker config) |
| `make install-hyperfleet` | Deploy API + Sentinels + Adapters (requires cluster credentials) |
| `make install-maestro` | Deploy Maestro server + agent (separate namespace) |
| `make create-maestro-consumer` | Register a Maestro consumer (requires Maestro running) |
| `make install-rabbitmq` | Install RabbitMQ for development (only for `BROKER_TYPE=rabbitmq`) |
| `make install-api` | Deploy HyperFleet API only |
| `make install-sentinels` | Deploy all Sentinels |
| `make install-adapters` | Deploy all Adapters |
| `make uninstall-rabbitmq` | Remove RabbitMQ deployment |
| `make uninstall-all` | Remove all Helm releases |
| `make status` | Show Helm releases and pod status |

### Makefile Variables

Override with `VAR=value`, e.g. `make install-hyperfleet BROKER_TYPE=rabbitmq`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_ENV` | `dev` | Terraform environment (selects `envs/gke/<TF_ENV>.tfvars` and `.tfbackend`) |
| `NAMESPACE` | `hyperfleet` | Kubernetes namespace for HyperFleet components |
| `MAESTRO_NS` | `maestro` | Kubernetes namespace for Maestro |
| `BROKER_TYPE` | `googlepubsub` | Message broker type (`googlepubsub` or `rabbitmq`) |
| `RABBITMQ_URL` | `amqp://guest:guest@rabbitmq:5672/` | RabbitMQ connection URL (only used when `BROKER_TYPE=rabbitmq`) |
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
├── manifests/
│   └── rabbitmq.yaml           # RabbitMQ dev manifest (for BROKER_TYPE=rabbitmq)
├── scripts/
│   └── tf-helm-values.sh      # Generates Helm values (Pub/Sub from Terraform, RabbitMQ from variables)
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

Running `make tf-helm-values` generates per-component YAML files in `generated-values-from-terraform/` with broker configuration. Each install target conditionally passes its generated file via `--values` if it exists.

The script behavior depends on `BROKER_TYPE`:

- **`googlepubsub`**: reads Terraform outputs (`gcp_project_id`, `kubernetes_namespace`) and generates Pub/Sub config (topic names, project ID, subscription IDs).
- **`rabbitmq`**: skips Terraform entirely, uses `RABBITMQ_URL` and `NAMESPACE` to generate RabbitMQ config (URL, exchange, queue names, routing keys).

| Generated File | Used By | Contents |
|----------------|---------|----------|
| `sentinel-clusters.yaml` | `install-sentinel-clusters` | Broker config for cluster events |
| `sentinel-nodepools.yaml` | `install-sentinel-nodepools` | Broker config for nodepool events |
| `adapter1.yaml` | `install-adapter1` | Broker config for adapter1 |
| `adapter2.yaml` | `install-adapter2` | Broker config for adapter2 |
| `adapter3.yaml` | `install-adapter3` | Broker config for adapter3 |

To clean up generated files: `make clean-generated`.

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

# Uninstall RabbitMQ (if installed)
make uninstall-rabbitmq

# Destroy Terraform-managed infrastructure (GCP only)
cd terraform && terraform destroy -var-file=envs/gke/dev.tfvars
```

## Related Repositories

- [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) - HyperFleet API server
- [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) - HyperFleet Sentinel
- [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) - HyperFleet Adapter Framework

## License

Apache License 2.0
