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
- **Per-developer clusters**: Each developer gets their own isolated GKE cluster (shared across multiple deployments)
- **Namespace scoping**: Pub/Sub resources are scoped to `{developer_name}-{kubernetes_suffix}` to allow multiple deployments per cluster
  - Why? Because the principal used in Workload Identity permissions is `.../<identity pool>/ns/<namespace>/sa/<k8s_sa_name>`
  - The `kubernetes_suffix` allows multiple terraform deployments to share a cluster but use different Pub/Sub resources
  - Example: Developer "alice" can have both `alice-test1` and `alice-test2` namespaces in the same `hyperfleet-dev-alice` cluster

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- [gke-gcloud-auth-plugin](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin) (for kubectl access)
- `kubectl`
- Access to the `hcm-hyperfleet` GCP project
- Shared infrastructure deployed (see [Shared Infrastructure](#shared-infrastructure) below)
- **Remote backend configured** (see [Remote Backend Setup](#remote-backend-setup) below)

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

> **Note**: The shared VPC and remote backend must be deployed first. See [Shared Infrastructure](#shared-infrastructure) and [Remote Backend Setup](#remote-backend-setup) below.

```bash
# 1. Authenticate with GCP
gcloud auth application-default login
gcloud config set project hcm-hyperfleet

# 2. Create your configuration files (both .tfvars and .tfbackend)
cd terraform
cp envs/gke/dev.tfvars.example envs/gke/dev-<username>.tfvars
cp envs/gke/dev.tfbackend.example envs/gke/dev-<username>.tfbackend

# 3. Edit your tfvars - set developer_name to your username
#    e.g., developer_name = "your-username"
#    Optionally customize kubernetes_suffix (default: "default")

# 4. Edit your tfbackend - set prefix to match your username
#    e.g., prefix = "terraform/state/dev-<username>"

# 5. Initialize Terraform with remote backend
terraform init -backend-config=envs/gke/dev-<username>.tfbackend

# 6. Plan (review what will be created)
terraform plan -var-file=envs/gke/dev-<username>.tfvars

# 7. Apply (create the cluster)
terraform apply -var-file=envs/gke/dev-<username>.tfvars

# 8. Connect to your cluster (command shown in terraform output)
gcloud container clusters get-credentials hyperfleet-dev-<username> \
  --zone us-central1-a \
  --project hcm-hyperfleet

# 9. Verify
kubectl get nodes

# 10. Query outputs (accessible to all team members)
terraform output
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

## Remote Backend Setup

State files are stored in a **GCS bucket** (`hyperfleet-terraform-state`) with automatic locking for team collaboration.

### One-Time Setup (Admin Only)

Create the backend bucket once:

```bash
cd terraform
./bootstrap/setup-backend.sh
```

### Team Member Setup

Request these IAM roles from your admin:
- `roles/storage.objectUser` - Read/write state files
- `roles/compute.admin` - Manage GKE
- `roles/container.admin` - Manage GKE resources
- `roles/iam.serviceAccountUser` - Use service accounts
- `roles/pubsub.admin` - Manage Pub/Sub (if enabled)

### Using the Backend

Each `.tfvars` file has a paired `.tfbackend` file:

```bash
# Personal dev cluster
cp envs/gke/dev.tfvars.example envs/gke/dev-<username>.tfvars
cp envs/gke/dev.tfbackend.example envs/gke/dev-<username>.tfbackend
# Edit both files to set your username
terraform init -backend-config=envs/gke/dev-<username>.tfbackend

# Shared cluster (e.g., Prow) - already configured
terraform init -backend-config=envs/gke/dev-prow.tfbackend
```

### Migrating Local State (If Needed)

If you have existing local state files:

```bash
# Backup first
cp terraform.tfstate terraform.tfstate.backup

# Initialize with backend (Terraform will offer to migrate)
terraform init -backend-config=envs/gke/dev-<username>.tfbackend
# Answer: yes

# Verify
terraform state list
```

### Switching Between Environments

To switch between different state files (e.g., personal cluster to Prow cluster):

```bash
# Switch to a different backend configuration
terraform init -reconfigure -backend-config=envs/gke/dev-prow.tfbackend

# Verify you're using the correct state
terraform state list
```

The `-reconfigure` flag switches the backend without migrating state.

## Destroying Your Cluster

**Always destroy your cluster when you're done to avoid unnecessary costs.**

### Personal Dev Clusters

```bash
terraform destroy -var-file=envs/gke/dev-<username>.tfvars
```

### Shared Long-Running Clusters

Shared clusters (like Prow) have **deletion protection enabled**. To destroy:

1. **Coordinate with team first!** (Post in Slack, wait for confirmation)
2. Disable protection in tfvars: `enable_deletion_protection = false`
3. Apply the change: `terraform apply -var-file=envs/gke/dev-prow.tfvars`
4. Destroy: `terraform destroy -var-file=envs/gke/dev-prow.tfvars`

## Configuration Options

| Variable | Description | Default |
|----------|-------------|---------|
| `developer_name` | Your username (used in cluster name) | **required** |
| `kubernetes_suffix` | Namespace suffix (allows multiple deployments per cluster) | `default` |
| `cloud_provider` | Cloud provider (`gke`, `eks`, `aks`) | `gke` |
| `gcp_project_id` | GCP project | `hcm-hyperfleet` |
| `gcp_zone` | GCP zone | `us-central1-a` |
| `gcp_network` | VPC network name | `hyperfleet-dev-vpc` |
| `gcp_subnetwork` | Subnet name | `hyperfleet-dev-vpc-subnet` |
| `node_count` | Number of nodes | `1` |
| `machine_type` | VM instance type | `e2-standard-4` |
| `use_spot_vms` | Use Spot VMs for cost savings | `true` |
| `enable_deletion_protection` | Enable deletion protection for shared clusters | `false` |
| `use_pubsub` | Use Google Pub/Sub for messaging (instead of RabbitMQ) | `false` |
| `enable_dead_letter` | Enable dead letter queue for Pub/Sub | `true` |
| `pubsub_topic_configs` | Map of Pub/Sub topic configurations with subscriptions and publishers | See below |

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
use_pubsub = true
enable_dead_letter = true  # Optional, defaults to true

# Configure topics with their subscriptions and publishers
pubsub_topic_configs = {
  clusters = {
    subscriptions = {
      landing-zone   = {}
      validation-gcp = {}
    }
    publishers = {
      sentinel = {}
    }
  }
  nodepools = {
    subscriptions = {
      validation-node-gcp = {}
    }
    publishers = {
      sentinel = {}
    }
  }
}
```

Or pass as command line arguments:

```bash
terraform apply -var-file=envs/gke/dev-<username>.tfvars \
  -var="use_pubsub=true"
```

### Customizing Topics, Subscriptions, and Publishers

Each topic can have its own set of subscriptions (adapters) and publishers. Per-subscription and per-publisher settings can be configured:

```hcl
pubsub_topic_configs = {
  clusters = {
    message_retention_duration = "604800s"  # 7 days (optional)
    subscriptions = {
      landing-zone = {
        ack_deadline_seconds = 60  # Default: 60
      }
      validation-gcp = {
        ack_deadline_seconds = 120  # Custom setting for this adapter
      }
    }
    publishers = {
      sentinel = {}  # Uses default roles: publisher and viewer
    }
  }
  nodepools = {
    subscriptions = {
      validation-node-gcp = {}  # Only validation-node-gcp subscribes to nodepools
    }
    publishers = {
      sentinel = {}
      custom-publisher = {
        roles = ["roles/pubsub.publisher"]  # Custom roles (optional)
      }
    }
  }
  volumes = {
    subscriptions = {
      landing-zone = {}
      orchestrator = {}
    }
    publishers = {
      sentinel = {}
    }
  }
}
```

When you add or remove topics/subscriptions/publishers and re-run `terraform apply`, the infrastructure will be updated accordingly.

### What It Creates

| Resource | Name Pattern | Description |
|----------|--------------|-------------|
| Pub/Sub Topics | `{developer_name}-{kubernetes_suffix}-{topic_name}` | Event topics (clusters, nodepools, etc.) |
| Pub/Sub Subscriptions | `{developer_name}-{kubernetes_suffix}-{topic_name}-{adapter}-adapter` | Subscriptions per topic per adapter |
| Dead Letter Topics | `{developer_name}-{kubernetes_suffix}-{topic_name}-dlq` | Failed message storage (optional) |
| Workload Identity Bindings | - | Direct WIF permissions for K8s service accounts |

**Example with developer `alice`, kubernetes_suffix `test1`, and config:**
```hcl
pubsub_topic_configs = {
  clusters = {
    subscriptions = { landing-zone = {}, validation-gcp = {} }
    publishers    = { sentinel = {} }
  }
  nodepools = {
    subscriptions = { validation-node-gcp = {} }
    publishers    = { sentinel = {} }
  }
}
```

**Creates:**
- **Topics:**
  - `alice-test1-clusters`
  - `alice-test1-nodepools`
- **Subscriptions:**
  - `alice-test1-clusters-landing-zone-adapter`
  - `alice-test1-clusters-validation-gcp-adapter`
  - `alice-test1-nodepools-validation-node-gcp-adapter`
- **Workload Identity Bindings:**
  - K8s SA `sentinel` in namespace `alice-test1` → publishes to clusters and nodepools topics
  - K8s SA `landing-zone-adapter` in namespace `alice-test1` → subscribes to clusters topic
  - K8s SA `validation-gcp-adapter` in namespace `alice-test1` → subscribes to clusters topic
  - K8s SA `validation-node-gcp-adapter` in namespace `alice-test1` → subscribes to nodepools topic

Each deployment gets completely isolated Pub/Sub resources - multiple deployments can share a cluster by using different kubernetes_suffix values.

### IAM Permissions

The module configures resource-level IAM permissions using Workload Identity Federation, following the principle of least privilege:

**Publisher Kubernetes Service Accounts** (configured per topic):
- Configurable roles per topic (default: `roles/pubsub.publisher` and `roles/pubsub.viewer`)
- `roles/pubsub.publisher` - Publish messages to the topic
- `roles/pubsub.viewer` - View topic metadata (required to check if topic exists)
- Authenticated via WIF principal directly (no GCP service account created)
- Example: `sentinel` service account gets publisher permissions on topics where it's configured

**Adapter Kubernetes Service Accounts** (`{adapter}-adapter`):
- `roles/pubsub.subscriber` on **their subscriptions** - Pull and acknowledge messages from subscriptions
- `roles/pubsub.viewer` on **their subscriptions** - View subscription metadata
- Authenticated via WIF principal directly (no GCP service account created)
- Each adapter only has access to its specific subscriptions

**Note**: This implementation uses Workload Identity Federation (WIF) principals directly, eliminating the need to create GCP service accounts. Kubernetes service accounts are granted permissions directly on Pub/Sub resources through WIF. Each Kubernetes service account can only access the specific resources they've been granted permissions for - publishers can only publish to their configured topics, and adapters cannot access topics directly or other adapters' subscriptions.

### Outputs

After applying with `use_pubsub=true`, you'll get these outputs:

```bash
# Get complete Pub/Sub resources (hierarchical view)
terraform output pubsub_resources

# Get ready-to-use Helm values snippet
terraform output helm_values_snippet
```

### Helm Configuration

Get the complete Helm values snippet (includes broker config and Workload Identity):

```bash
terraform output helm_values_snippet
```

The output includes configurations organized by topic, showing the Helm chart configurations for publishers and adapters (subscribers) grouped by the topic they interact with.

**Example output structure:**
```yaml
# ============================================================================
# Services for Clusters Topic
# ============================================================================
# Publishers (publish to clusters topic)
clusters-sentinel:
  serviceAccount:
    name: "sentinel"  # K8s SA name for this publisher
  broker:
    type: googlepubsub
    topic: alice-test1-clusters
    googlepubsub:
      projectId: hcm-hyperfleet

# Adapters (subscribe to clusters topic)
clusters-landing-zone-adapter:
  serviceAccount:
    name: landing-zone-adapter
  broker:
    type: googlepubsub
    googlepubsub:
      projectId: hcm-hyperfleet
      topic: alice-test1-clusters
      subscription: alice-test1-clusters-landing-zone-adapter

clusters-validation-gcp-adapter:
  # Similar configuration for validation-gcp adapter...

# ============================================================================
# Services for Nodepools Topic
# ============================================================================
# Sentinel (publishes to nodepools topic)
nodepools-sentinel:
  serviceAccount:
    name: "sentinel"  # Same K8s SA as clusters-sentinel
  broker:
    type: googlepubsub
    topic: alice-test1-nodepools
    googlepubsub:
      projectId: hcm-hyperfleet

# Adapters (subscribe to nodepools topic)
nodepools-validation-gcp-adapter:
  # Configuration for validation-gcp adapter on nodepools topic...
```

**Note**: While each topic has a separate Helm configuration section (e.g., `clusters-sentinel`, `nodepools-sentinel`), they all use the **same** Kubernetes service account (`sentinel`). This single Kubernetes service account has permission to publish to all topics via Workload Identity Federation. No GCP service accounts are created - permissions are granted directly to Kubernetes service accounts. Adapter service configurations are grouped by the topic they subscribe to for clarity.

**Chart Structure Note**: The hyperfleet-gcp chart uses a base + overlay pattern:
- `base:` - Core platform components (API, Sentinel, Landing Zone, RabbitMQ)
- Root level - GCP-specific components (validation-gcp)

When constructing your values file, sentinel and landing-zone configs go under the `base:` prefix while validation-gcp stays at root level. See the [hyperfleet-chart README](https://github.com/openshift-hyperfleet/hyperfleet-chart) for full documentation.

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
terraform init -backend-config=shared.tfbackend
terraform plan
terraform apply
```

### Destroy Shared Infrastructure

> **Warning**: Only destroy when ALL developer clusters have been destroyed first!

```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
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

### "Error acquiring the state lock"
Another team member is currently running an operation. Wait for them to complete. If the lock is stale, use `terraform force-unlock <lock-id>`.
