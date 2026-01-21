# HyperFleet Infrastructure

Infrastructure as Code for HyperFleet development environments.

## Overview

This repository contains Terraform configurations for:

- **Shared infrastructure** (VPC, subnets, firewall rules) - deployed once per GCP project, used by all developer clusters
- **Developer GKE clusters** - personal Kubernetes clusters for each developer
- **Google Pub/Sub** (optional) - managed message broker with Workload Identity

### Shared Infrastructure Resources

The `terraform/shared` module provides the following resources (deployed once by a team admin):

| Resource | Name | Purpose |
|----------|------|---------|
| VPC | `hyperfleet-dev-vpc` | Virtual network for all dev clusters |
| Subnet | `hyperfleet-dev-vpc-subnet` | Node IPs (10.100.0.0/16) |
| Secondary Range | `pods` | Pod IPs (10.101.0.0/16) |
| Secondary Range | `services` | Service IPs (10.102.0.0/16) |
| Firewall | `hyperfleet-dev-vpc-allow-internal` | Allow traffic within VPC |
| Firewall | `hyperfleet-dev-vpc-allow-iap-ssh` | Allow SSH via Identity-Aware Proxy |
| Cloud Router | `hyperfleet-dev-vpc-router` | Required for Cloud NAT |
| Cloud NAT | `hyperfleet-dev-vpc-nat` | Internet access for private nodes |

## Quick Start

See [terraform/README.md](terraform/README.md) for detailed instructions.

### Shared Infrastructure (One-time Setup)

```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
terraform apply
```

### Developer Clusters

```bash
cd terraform
cp envs/gke/dev.tfvars.example envs/gke/dev-<username>.tfvars
cp envs/gke/dev.tfbackend.example envs/gke/dev-<username>.tfbackend
# Edit both files: set developer_name and prefix to your username
terraform init -backend-config=envs/gke/dev-<username>.tfbackend
terraform apply -var-file=envs/gke/dev-<username>.tfvars
```

## Repository Structure

```
hyperfleet-infra/
├── README.md                   # This file
├── LICENSE
├── terraform/
│   ├── README.md               # Detailed Terraform documentation
│   ├── main.tf                 # Root module (developer clusters)
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── versions.tf
│   ├── backend.tf              # Remote state backend configuration
│   ├── bootstrap/              # One-time setup scripts
│   │   └── setup-backend.sh    # Creates GCS bucket for Terraform state
│   ├── shared/                 # Shared infrastructure (deploy once)
│   │   ├── README.md
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── versions.tf
│   │   ├── backend.tf
│   │   └── shared.tfbackend    # Backend config for shared infrastructure
│   ├── modules/
│   │   ├── cluster/
│   │   │   └── gke/            # GKE cluster module
│   │   └── pubsub/             # Google Pub/Sub module
│   └── envs/
│       └── gke/
│           ├── dev.tfbackend.example  # Backend configuration template
│           ├── dev.tfvars.example     # Variables template
│           ├── dev-prow.tfbackend     # Prow cluster backend config
│           └── dev-prow.tfvars        # Prow cluster variables
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
- [adapter-landing-zone](https://github.com/openshift-hyperfleet/adapter-landing-zone) - Landing Zone adapter
- [adapter-validation-gcp](https://github.com/openshift-hyperfleet/adapter-validation-gcp) - GCP Validation adapter
- [hyperfleet-chart](https://github.com/openshift-hyperfleet/hyperfleet-chart) - Helm charts (base + cloud overlays)

## License

Apache License 2.0
