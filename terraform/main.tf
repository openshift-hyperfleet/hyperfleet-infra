locals {
  cluster_name         = "hyperfleet-dev-${var.developer_name}"
  kubernetes_namespace = "${var.developer_name}-${var.kubernetes_suffix}"

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

  # Deletion protection for shared/production clusters
  enable_deletion_protection = var.enable_deletion_protection
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
  count  = var.use_pubsub ? 1 : 0

  project_id           = var.gcp_project_id
  kubernetes_namespace = local.kubernetes_namespace

  # Topic configurations with subscriptions and publishers
  topic_configs = var.pubsub_topic_configs

  # Dead letter queue
  enable_dead_letter    = var.enable_dead_letter
  max_delivery_attempts = 5

  labels = local.common_labels
}

# =============================================================================
# External API Access (optional firewall rule for LoadBalancer health checks)
# =============================================================================
resource "google_compute_firewall" "allow_lb_health_checks" {
  count   = var.enable_external_api && var.cloud_provider == "gke" ? 1 : 0
  name    = "${local.cluster_name}-allow-lb-health-checks"
  network = var.gcp_network
  project = var.gcp_project_id

  allow {
    protocol = "tcp"
    ports    = ["8000"] # HyperFleet API port
  }

  # GCP Load Balancer health check source ranges
  # https://cloud.google.com/load-balancing/docs/health-check-concepts#ip-ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]

  # Target GKE nodes
  target_tags = ["gke-${local.cluster_name}"]

  description = "Allow GCP health checks for LoadBalancer services exposing HyperFleet API"
}

# =============================================================================
# Maestro (optional)
# =============================================================================
module "maestro" {
  source = "./modules/maestro"
  count  = var.use_maestro ? 1 : 0

  namespace          = "maestro"
  consumer_name      = var.maestro_consumer_name
  server_replicas    = var.maestro_server_replicas
  enable_postgres    = var.maestro_enable_postgres
  enable_mqtt_broker = var.maestro_enable_mqtt_broker
  labels             = local.common_labels

  depends_on = [module.gke_cluster]
}
