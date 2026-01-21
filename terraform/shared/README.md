# HyperFleet Shared Infrastructure

This Terraform configuration creates the shared networking infrastructure that all developer GKE clusters use.

**This should only be run once by a team admin.**

## What It Creates

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

## Prerequisites

- Terraform >= 1.5
- `gcloud` CLI authenticated
- Admin access to `hcm-hyperfleet` GCP project
- **Remote backend bucket created** (run `../bootstrap/setup-backend.sh` first)
  - Configures versioning and lifecycle policy (keeps 5 recent versions OR deletes versions >90 days old)

## Usage

### Authenticate with GCP
```bash
gcloud auth application-default login
gcloud config set project hcm-hyperfleet
```

### New Deployment

```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
terraform plan
terraform apply
```

### Migrating Existing Infrastructure

If shared infrastructure already exists with local state, migrate to remote backend:

```bash
cd terraform/shared

# Backup local state
cp terraform.tfstate terraform.tfstate.backup

# Initialize with backend - Terraform will detect local state and offer to migrate
terraform init -backend-config=shared.tfbackend
# Answer: yes

# Verify migration succeeded
terraform state list
terraform plan  # Should show "No changes"
```

State is stored at `terraform/state/shared/networking` in the GCS backend for team coordination.

## Outputs

After applying, the outputs will show the values developers need:

```
network_name = "hyperfleet-dev-vpc"
subnet_name  = "hyperfleet-dev-vpc-subnet"
```

These are already set as defaults in the developer tfvars template, so developers don't need to change anything.

## Destroying

> **Warning**: Only destroy when ALL developer clusters have been destroyed first!

To check for existing clusters:
```bash
gcloud container clusters list --project=hcm-hyperfleet --filter="name~hyperfleet-dev-"
```

If no clusters exist, you can safely destroy:
```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
terraform destroy
```

**Note:** The state is in the remote backend, so any team member with proper IAM permissions can run destroy (but coordinate with the team first!).

## Network Architecture

```
hyperfleet-dev-vpc (10.100.0.0/16)
├── hyperfleet-dev-vpc-subnet
│   ├── Primary range: 10.100.0.0/16 (node IPs)
│   ├── Secondary 'pods': 10.101.0.0/16 (pod IPs)
│   └── Secondary 'services': 10.102.0.0/16 (service IPs)
├── Cloud NAT (for outbound internet)
└── Firewall rules
    ├── allow-internal (VPC internal traffic)
    └── allow-iap-ssh (SSH via IAP)
```

## Configuration

The defaults should work for most cases, but you can customize via variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `project_id` | GCP project ID | `hcm-hyperfleet` |
| `region` | GCP region | `us-central1` |
| `network_name` | VPC name | `hyperfleet-dev-vpc` |
| `subnet_cidr` | Subnet CIDR | `10.100.0.0/16` |
| `pods_cidr` | Pods secondary range | `10.101.0.0/16` |
| `services_cidr` | Services secondary range | `10.102.0.0/16` |

## Troubleshooting

### "Resource already exists" error
The shared infrastructure may have been partially created. Import existing resources or destroy and recreate.

### Developers can't create clusters
Ensure the VPC and subnet exist:
```bash
gcloud compute networks list --project=hcm-hyperfleet --filter="name=hyperfleet-dev-vpc"
gcloud compute networks subnets list --project=hcm-hyperfleet --network=hyperfleet-dev-vpc
```
