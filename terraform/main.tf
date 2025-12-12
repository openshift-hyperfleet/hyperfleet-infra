locals {
  cluster_name = "hyperfleet-dev-${var.developer_name}"

  common_labels = {
    environment = "dev"
    owner       = var.developer_name
    managed-by  = "terraform"
    project     = "hyperfleet"
  }
}

# =============================================================================
# GKE Cluster (when cloud_provider = "gke")
# =============================================================================
module "gke_cluster" {
  source = "./modules/cluster/gke"
  count  = var.cloud_provider == "gke" ? 1 : 0

  project_id   = var.gcp_project_id
  cluster_name = local.cluster_name
  region       = var.gcp_region
  zone         = var.gcp_zone
  network      = var.gcp_network
  subnetwork   = var.gcp_subnetwork
  node_count   = var.node_count
  machine_type = var.machine_type
  use_spot_vms = var.use_spot_vms
  labels       = local.common_labels
}

# =============================================================================
# EKS Cluster (future - when cloud_provider = "eks")
# =============================================================================
# module "eks_cluster" {
#   source = "./modules/cluster/eks"
#   count  = var.cloud_provider == "eks" ? 1 : 0
#   ...
# }

# =============================================================================
# AKS Cluster (future - when cloud_provider = "aks")
# =============================================================================
# module "aks_cluster" {
#   source = "./modules/cluster/aks"
#   count  = var.cloud_provider == "aks" ? 1 : 0
#   ...
# }

# =============================================================================
# Google Pub/Sub for HyperFleet messaging (optional)
# =============================================================================
module "pubsub" {
  source = "./modules/pubsub"
  count  = var.enable_pubsub ? 1 : 0

  project_id    = var.gcp_project_id
  namespace     = var.kubernetes_namespace
  resource_type = "clusters"

  # Service account names
  sentinel_sa_name   = "hyperfleet-sentinel-${var.developer_name}"
  adapter_sa_name    = "hyperfleet-adapter-${var.developer_name}"
  sentinel_k8s_sa_name = "sentinel"
  adapter_k8s_sa_name  = "hyperfleet-adapter"

  # Dead letter queue
  enable_dead_letter    = var.enable_dead_letter
  max_delivery_attempts = 5

  labels = local.common_labels
}
