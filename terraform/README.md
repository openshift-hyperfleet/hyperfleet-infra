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

### Using Shared Configuration

For shared environment configuration, use `dev-shared.tfvars` in addition to your personal tfvars:

```bash
# Apply with both shared and personal configuration
terraform apply \
  -var-file=envs/gke/dev-shared.tfvars \
  -var-file=envs/gke/dev-<username>.tfvars
```

Personal tfvars override shared values, so you can customize specific settings while inheriting common defaults.

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
| `kubernetes_namespace` | Kubernetes namespace for Workload Identity binding | `hyperfleet-system` |
| `use_pubsub` | Use Google Pub/Sub for messaging (instead of RabbitMQ) | `false` |
| `enable_dead_letter` | Enable dead letter queue for Pub/Sub | `true` |
| `pubsub_topic_configs` | Map of Pub/Sub topic configurations with adapter subscriptions | See below |

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
kubernetes_namespace = "hyperfleet-system"  # Kubernetes namespace for Workload Identity binding
use_pubsub = true
enable_dead_letter = true  # Optional, defaults to true

# Configure topics and their adapter subscriptions
pubsub_topic_configs = {
  clusters = {
    adapter_subscriptions = {
      landing-zone   = {}
      validation-gcp = {}
    }
  }
  nodepools = {
    adapter_subscriptions = {
      validation-gcp = {}
    }
  }
}
```

Or pass as command line arguments:

```bash
terraform apply -var-file=envs/gke/dev-<username>.tfvars \
  -var="use_pubsub=true"
```

### Customizing Topics and Subscriptions

Each topic can have its own set of adapter subscriptions. Per-subscription settings can be configured:

```hcl
pubsub_topic_configs = {
  clusters = {
    message_retention_duration = "604800s"  # 7 days (optional)
    adapter_subscriptions = {
      landing-zone = {
        ack_deadline_seconds = 60  # Default: 60
      }
      validation-gcp = {
        ack_deadline_seconds = 120  # Custom setting for this adapter
      }
    }
  }
  nodepools = {
    adapter_subscriptions = {
      validation-gcp = {}  # Only validation-gcp subscribes to nodepools
    }
  }
  volumes = {
    adapter_subscriptions = {
      landing-zone = {}
      orchestrator = {}
    }
  }
}
```

When you add or remove topics/subscriptions and re-run `terraform apply`, the infrastructure will be updated accordingly.

> **Note**: The `helm_values_snippet` output assumes each adapter subscribes to at most ONE topic. If an adapter is configured for multiple topics (like `landing-zone` above), only the first topic (alphabetically) will be included in the Helm values. The Pub/Sub resources (topics, subscriptions, IAM) will be created correctly for all configured subscriptions.

### What It Creates

| Resource | Name Pattern | Description |
|----------|--------------|-------------|
| Pub/Sub Topics | `{kubernetes_namespace}-{topic_name}-{developer}` | Event topics (clusters, nodepools, etc.) |
| Pub/Sub Subscriptions | `{kubernetes_namespace}-{topic_name}-{adapter}-adapter-{developer}` | Subscriptions per topic per adapter |
| Dead Letter Topics | `{kubernetes_namespace}-{topic_name}-{developer}-dlq` | Failed message storage (optional) |
| Service Accounts | `sentinel-{developer}` | Single publisher SA for all topics (one sentinel publishes to all topics) |
| Service Accounts | `{adapter}-{developer}` | Subscriber SA per unique adapter |
| Workload Identity | - | Binds K8s SAs to GCP SAs |

**Example with developer `alice` and config:**
```hcl
pubsub_topic_configs = {
  clusters  = { adapter_subscriptions = { landing-zone = {}, validation-gcp = {} } }
  nodepools = { adapter_subscriptions = { validation-gcp = {} } }
}
```

**Creates:**
- **Topics:**
  - `hyperfleet-system-clusters-alice`
  - `hyperfleet-system-nodepools-alice`
- **Subscriptions:**
  - `hyperfleet-system-clusters-landing-zone-adapter-alice`
  - `hyperfleet-system-clusters-validation-gcp-adapter-alice`
  - `hyperfleet-system-nodepools-validation-gcp-adapter-alice`
- **Service Accounts:**
  - `sentinel-alice` (publishes to all topics: clusters, nodepools)
  - `landing-zone-alice` (subscribes to clusters only)
  - `validation-gcp-alice` (subscribes to both topics)

Each developer gets completely isolated Pub/Sub resources - no conflicts between developer environments.

### IAM Permissions

The module configures resource-level IAM permissions following the principle of least privilege:

**Sentinel Service Account** (`sentinel-{developer}`):
- `roles/pubsub.publisher` on **all topics** - Publish messages to any topic
- `roles/pubsub.viewer` on **all topics** - View topic metadata (required to check if topic exists)
- `roles/iam.workloadIdentityUser` on **service account** - Allow K8s SA `sentinel` to impersonate this GCP SA

**Adapter Service Accounts** (`{adapter}-{developer}`):
- `roles/pubsub.subscriber` on **their subscriptions** - Pull and acknowledge messages from subscriptions across all topics
- `roles/pubsub.viewer` on **their subscriptions** - View subscription metadata
- `roles/iam.workloadIdentityUser` on **service account** - Allow K8s SA `{adapter}-adapter` to impersonate this GCP SA

**Note**: These are resource-level IAM bindings, not project-level roles. There is one shared sentinel GCP service account with publish access to all topics. Each adapter has one GCP service account that can access their subscriptions across all topics, but adapters cannot access topics directly or other adapters' subscriptions.

### Outputs

After applying with `use_pubsub=true`, you'll get these outputs:

```bash
# Get complete Pub/Sub resources (hierarchical view)
terraform output pubsub_resources

# Get service account emails for Helm values
terraform output sentinel_service_account   # Sentinel email (shared across all topics)
terraform output adapter_service_accounts

# Get ready-to-use Helm values snippet
terraform output helm_values_snippet
```

### Helm Configuration

Get the complete Helm values snippet (includes broker config and Workload Identity):

```bash
terraform output helm_values_snippet
```

The output is formatted for the **hyperfleet-gcp** overlay chart structure:
- Base chart components (sentinel, landing-zone) are nested under the `base:` prefix
- GCP overlay components (validation-gcp) are at the root level

**Example output structure:**
```yaml
# =============================================================================
# HyperFleet Helm Values for GCP with Pub/Sub
# Generated by terraform - use with charts/hyperfleet-gcp
#
# Usage:
#   helm install hyperfleet charts/hyperfleet-gcp -f <this-file> -n hyperfleet-system
# =============================================================================

# Base chart overrides (API, Sentinel, Landing Zone)
base:
  global:
    broker:
      type: googlepubsub
      googlepubsub:
        enabled: true
        projectId: "hcm-hyperfleet"
        createTopicIfMissing: false
        createSubscriptionIfMissing: false
      rabbitmq:
        enabled: false

  # Sentinel - publishes to hyperfleet-system-clusters-alice
  sentinel:
    serviceAccount:
      create: true
      name: sentinel
      annotations:
        iam.gke.io/gcp-service-account: sentinel-alice@hcm-hyperfleet.iam.gserviceaccount.com
    broker:
      type: googlepubsub
      topic: hyperfleet-system-clusters-alice
      googlepubsub:
        projectId: hcm-hyperfleet

  # Landing Zone Adapter - subscribes to hyperfleet-system-clusters-alice
  landing-zone:
    serviceAccount:
      create: true
      name: landing-zone-adapter
      annotations:
        iam.gke.io/gcp-service-account: landing-zone-alice@hcm-hyperfleet.iam.gserviceaccount.com
    broker:
      type: googlepubsub
      googlepubsub:
        projectId: hcm-hyperfleet
        topic: hyperfleet-system-clusters-alice
        subscription: hyperfleet-system-clusters-landing-zone-adapter-alice
        deadLetterTopic: hyperfleet-system-clusters-alice-dlq

  # Disable RabbitMQ when using Pub/Sub
  rabbitmq:
    enabled: false

# GCP Validation Adapter (GCP overlay chart component - NOT under base:)
# Subscribes to hyperfleet-system-clusters-alice
validation-gcp:
  enabled: true
  serviceAccount:
    create: true
    name: validation-gcp-adapter
    annotations:
      iam.gke.io/gcp-service-account: validation-gcp-alice@hcm-hyperfleet.iam.gserviceaccount.com
  broker:
    type: googlepubsub
    googlepubsub:
      projectId: hcm-hyperfleet
      topic: hyperfleet-system-clusters-alice
      subscription: hyperfleet-system-clusters-validation-gcp-adapter-alice
      deadLetterTopic: hyperfleet-system-clusters-alice-dlq
```

**Chart Structure Note**: The hyperfleet-gcp chart uses a base + overlay pattern:
- `base:` - Core platform components (API, Sentinel, Landing Zone, RabbitMQ)
- Root level - GCP-specific components (validation-gcp)

See the [hyperfleet-chart README](https://github.com/openshift-hyperfleet/hyperfleet-chart) for full documentation.

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
