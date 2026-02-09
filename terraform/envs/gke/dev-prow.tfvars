# HyperFleet GKE Developer Environment - Long-running Reserved Cluster Used for Prow
#
# Usage:
#   terraform init -backend-config=envs/gke/dev-prow.tfbackend
#   terraform plan -var-file=envs/gke/dev-prow.tfvars
#   terraform apply -var-file=envs/gke/dev-prow.tfvars

# =============================================================================
# Required: Your Info
# =============================================================================
developer_name = "prow" # Your username (e.g., "your-username")
kubernetes_suffix  = "hyperfleet"    # Namespace suffix (allows multiple deployments to share a cluster)

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
node_count   = 1              # Start with 1 node for dev
machine_type = "e2-standard-4" # 4 vCPU, 16GB RAM
use_spot_vms = true           # ~70% cost savings, may be preempted

# IMPORTANT: Enable deletion protection for this shared long-running cluster
# This prevents accidental deletion via terraform destroy
# To destroy, you must first set this to false, apply, then destroy
enable_deletion_protection = true

# =============================================================================
# Pub/Sub Configuration (for HyperFleet messaging)
# =============================================================================
use_pubsub           = true                # Set to true to use Google Pub/Sub for event messaging
enable_dead_letter   = true                # Enable dead letter queue for failed messages

# Topic configurations - each topic can have different subscriptions and publishers
# Uncomment and customize as needed for your development environment
pubsub_topic_configs = {
  clusters = {
    subscribers = {
      adapter2 = {}
      adapter1 = {}
    }
    publishers = {
      sentinel = {}
    }
  }
  nodepools = {
    subscribers = {
      adapter3 = {}
    }
    publishers = {
      sentinel = {}
    }
  }
}
