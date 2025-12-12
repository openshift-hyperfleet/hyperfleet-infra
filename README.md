# HyperFleet Infrastructure

Infrastructure as Code for HyperFleet development environments.

## Overview

This repository contains Terraform configurations for:

- **Shared infrastructure** (VPC, subnets, firewall rules) - deployed once per GCP project, used by all developer clusters
- **Developer GKE clusters** - personal Kubernetes clusters for each developer
- **Google Pub/Sub** (optional) - managed message broker with Workload Identity

## Quick Start

See [terraform/README.md](terraform/README.md) for detailed instructions.

### Shared Infrastructure (One-time Setup)

```bash
cd terraform/shared
terraform init
terraform apply
```

### Developer Clusters

```bash
cd terraform
terraform init
cp envs/gke/dev.tfvars.example envs/gke/dev-<username>.tfvars
# Edit the file: set developer_name = "your-username"
terraform apply -var-file=envs/gke/dev-<username>.tfvars
```

## Repository Structure

```
hyperfleet-infra/
├── README.md                   # This file
├── terraform/
│   ├── README.md               # Detailed Terraform documentation
│   ├── main.tf                 # Root module (developer clusters)
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── versions.tf
│   ├── shared/                 # Shared infrastructure (deploy once)
│   │   ├── README.md
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── modules/
│   │   ├── cluster/
│   │   │   └── gke/            # GKE cluster module
│   │   └── pubsub/             # Google Pub/Sub module
│   └── envs/
│       └── gke/
│           └── dev.tfvars.example
```

## Prerequisites

- Terraform >= 1.5
- Google Cloud SDK (`gcloud`)
- `gke-gcloud-auth-plugin`
- `kubectl`
- Access to the GCP project

## Related Repositories

- [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) - HyperFleet API server
- [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) - HyperFleet Sentinel
- [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) - HyperFleet Adapter
- [hyperfleet-chart](https://github.com/openshift-hyperfleet/hyperfleet-chart) - Helm chart for deployment

## License

Apache License 2.0
