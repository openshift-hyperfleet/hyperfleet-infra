# HyperFleet Infrastructure - Terraform

Terraform configuration for creating personal HyperFleet development clusters.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     hcm-hyperfleet project                      │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              hyperfleet-dev-vpc (shared)                  │  │
│  │                                                           │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │  │
│  │  │ hyperfleet- │  │ hyperfleet- │  │ hyperfleet- │       │  │
│  │  │ dev-alice   │  │ dev-bob     │  │ dev-carol   │  ...  │  │
│  │  │ (GKE)       │  │ (GKE)       │  │ (GKE)       │       │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘       │  │
│  │                                                           │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

- **Shared VPC**: One VPC for all dev clusters (deployed once per project)
- **Per-developer clusters**: Each developer gets their own isolated GKE cluster

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- [gke-gcloud-auth-plugin](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin) (for kubectl access)
- `kubectl`
- Access to the `hcm-hyperfleet` GCP project
- Shared infrastructure deployed (see [Shared Infrastructure](#shared-infrastructure) below)

### Installing gke-gcloud-auth-plugin

```bash
# If gcloud was installed via package manager (dnf/apt):
sudo dnf install google-cloud-sdk-gke-gcloud-auth-plugin  # Fedora/RHEL
# OR
sudo apt-get install google-cloud-sdk-gke-gcloud-auth-plugin  # Debian/Ubuntu

# If gcloud was installed via gcloud installer:
gcloud components install gke-gcloud-auth-plugin
```

## Quick Start (For Developers)

> **Note**: The shared VPC must be deployed first. See [Shared Infrastructure](#shared-infrastructure) below.

```bash
# 1. Authenticate with GCP
gcloud auth application-default login
gcloud config set project hcm-hyperfleet

# 2. Initialize Terraform
cd terraform
terraform init

# 3. Create your tfvars file
cp envs/gke/dev.tfvars.example envs/gke/dev-<username>.tfvars

# 4. Edit your tfvars - set developer_name to your username
#    e.g., developer_name = "your-username"

# 5. Plan (review what will be created)
terraform plan -var-file=envs/gke/dev-<username>.tfvars

# 6. Apply (create the cluster)
terraform apply -var-file=envs/gke/dev-<username>.tfvars

# 7. Connect to your cluster (command shown in terraform output)
gcloud container clusters get-credentials hyperfleet-dev-<username> \
  --zone us-central1-a \
  --project hcm-hyperfleet

# 8. Verify
kubectl get nodes
```

## Destroying Your Cluster

**Always destroy your cluster when you're done to avoid unnecessary costs.**

```bash
terraform destroy -var-file=envs/gke/dev-<username>.tfvars
```

## Configuration Options

| Variable | Description | Default |
|----------|-------------|---------|
| `developer_name` | Your username (used in cluster name) | **required** |
| `cloud_provider` | Cloud provider (`gke`, `eks`, `aks`) | `gke` |
| `gcp_project_id` | GCP project | `hcm-hyperfleet` |
| `gcp_zone` | GCP zone | `us-central1-a` |
| `gcp_network` | VPC network name | `hyperfleet-dev-vpc` |
| `gcp_subnetwork` | Subnet name | `hyperfleet-dev-vpc-subnet` |
| `node_count` | Number of nodes | `1` |
| `machine_type` | VM instance type | `e2-standard-4` |
| `use_spot_vms` | Use Spot VMs for cost savings | `true` |
| `enable_pubsub` | Enable Google Pub/Sub resources | `false` |
| `enable_dead_letter` | Enable dead letter queue for Pub/Sub | `true` |
| `kubernetes_namespace` | Namespace for Workload Identity bindings | `hyperfleet-system` |

## Cost Optimization

- **Spot VMs** are enabled by default (~70% cost savings)
- Spot VMs may be preempted with 30 seconds notice
- For stable workloads, set `use_spot_vms = false`
- **Always destroy when done** - clusters cost ~$3-5/day with Spot VMs

## Google Pub/Sub (Optional)

Enable Pub/Sub to use Google's managed message broker instead of RabbitMQ.

### Enable Pub/Sub

Add to your tfvars file:

```hcl
enable_pubsub = true
enable_dead_letter = true  # Optional, defaults to true
kubernetes_namespace = "hyperfleet-system"
```

Or pass as command line arguments:

```bash
terraform apply -var-file=envs/gke/dev-<username>.tfvars \
  -var="enable_pubsub=true"
```

### What It Creates

| Resource | Name Pattern | Description |
|----------|--------------|-------------|
| Pub/Sub Topic | `{namespace}-clusters` | Event topic for cluster resources |
| Pub/Sub Subscription | `{namespace}-adapter` | Subscription for adapter service |
| Dead Letter Topic | `{namespace}-clusters-dlq` | Failed message storage (optional) |
| Service Account | `hyperfleet-sentinel-{developer}` | Publisher SA for sentinel |
| Service Account | `hyperfleet-adapter-{developer}` | Subscriber SA for adapter |
| Workload Identity | - | Binds K8s SAs to GCP SAs |

### Outputs

After applying with `enable_pubsub=true`, you'll get these outputs:

```bash
# Get service account emails for Helm values
terraform output sentinel_service_account_email
terraform output adapter_service_account_email

# Get topic/subscription names
terraform output topic_name
terraform output subscription_name

# Get ready-to-use Helm values snippet
terraform output helm_values_snippet
```

### Helm Configuration

Get the complete Helm values snippet (includes broker config and Workload Identity):

```bash
terraform output helm_values_snippet
```

Or manually add the Workload Identity annotations:

```yaml
sentinel:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: <sentinel_service_account_email>

hyperfleet-adapter:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: <adapter_service_account_email>
```

## Directory Structure

```
terraform/
├── main.tf                 # Root module (developer clusters)
├── variables.tf            # Input variables
├── outputs.tf              # Cluster outputs
├── providers.tf            # Provider configuration
├── versions.tf             # Version constraints
├── shared/                 # Shared infrastructure (deploy once)
│   ├── main.tf             # VPC, subnet, firewall, NAT
│   ├── variables.tf
│   ├── outputs.tf
│   └── README.md
├── modules/
│   ├── cluster/
│   │   └── gke/            # GKE cluster module
│   └── pubsub/             # Google Pub/Sub module
└── envs/
    └── gke/
        └── dev.tfvars.example
```

## Shared Infrastructure

The `shared/` directory contains Terraform for the VPC and networking that developer clusters use.

**This only needs to be deployed once per GCP project.**

### What It Creates

| Resource | Name | Description |
|----------|------|-------------|
| VPC | `hyperfleet-dev-vpc` | Virtual network for all dev clusters |
| Subnet | `hyperfleet-dev-vpc-subnet` | 10.100.0.0/16 for node IPs |
| Secondary Range | `pods` | 10.101.0.0/16 for pod IPs |
| Secondary Range | `services` | 10.102.0.0/16 for service IPs |
| Firewall | `allow-internal` | Allow traffic within VPC |
| Firewall | `allow-iap-ssh` | Allow SSH via IAP |
| Cloud NAT | `hyperfleet-dev-vpc-nat` | Internet access for private nodes |

### Deploy Shared Infrastructure

```bash
cd terraform/shared
terraform init
terraform plan
terraform apply
```

### Destroy Shared Infrastructure

> **Warning**: Only destroy when ALL developer clusters have been destroyed first!

```bash
cd terraform/shared
terraform destroy
```

See [shared/README.md](shared/README.md) for more details.

## Multi-Cloud Support

The configuration is designed to support multiple cloud providers. Currently only GKE is implemented.

To add EKS or AKS support in the future:
1. Create `modules/cluster/eks/` or `modules/cluster/aks/`
2. Add the module call in `main.tf`
3. Update outputs in `outputs.tf`

## Troubleshooting

### "No network named X" error
The shared VPC hasn't been deployed yet. Deploy it first:
```bash
cd terraform/shared && terraform apply
```

### "Quota exceeded" error
Your GCP project may have hit resource limits. Check quotas in the GCP Console or use a different zone.

### Cluster creation times out
GKE cluster creation typically takes 5-10 minutes. If it takes longer, check the GCP Console for errors.
