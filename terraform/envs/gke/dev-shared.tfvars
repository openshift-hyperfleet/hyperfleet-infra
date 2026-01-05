# HyperFleet GKE Developer Shared Environment - Long-running Reserved Cluster
#
# Usage:
#   terraform plan -var-file=envs/gke/dev-shared.tfvars
#   terraform apply -var-file=envs/gke/dev-shared.tfvars

# =============================================================================
# Required: Your Info
# =============================================================================
developer_name = "shared" # Your username (e.g., "your-username")

# =============================================================================
# Cloud Provider
# =============================================================================
cloud_provider = "gke"

# =============================================================================
# GCP Settings
# =============================================================================
gcp_project_id = "hcm-hyperfleet"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"

# Network (created by shared infra - don't change unless you know what you're doing)
gcp_network    = "hyperfleet-dev-vpc"
gcp_subnetwork = "hyperfleet-dev-vpc-subnet"

# =============================================================================
# Cluster Configuration
# =============================================================================
node_count   = 1               # Start with 1 node for dev
machine_type = "e2-standard-4" # 4 vCPU, 16GB RAM
use_spot_vms = true            # ~70% cost savings, may be preempted

# =============================================================================
# Pub/Sub Configuration (for HyperFleet messaging)
# =============================================================================
use_pubsub           = true                # Set to true to use Google Pub/Sub for event messaging
kubernetes_namespace = "hyperfleet-system" # Kubernetes namespace for Workload Identity binding
enable_dead_letter   = true                # Enable dead letter queue for failed messages

# Topic configurations - each topic can have different adapter subscriptions
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
