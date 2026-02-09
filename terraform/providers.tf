provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# =============================================================================
# Kubernetes & Helm Providers (for Maestro installation)
# =============================================================================

# Get GKE cluster access token
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = var.cloud_provider == "gke" && length(module.gke_cluster) > 0 ? "https://${module.gke_cluster[0].endpoint}" : ""
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = var.cloud_provider == "gke" && length(module.gke_cluster) > 0 ? base64decode(module.gke_cluster[0].ca_certificate) : ""
}

provider "helm" {
  kubernetes {
    host                   = var.cloud_provider == "gke" && length(module.gke_cluster) > 0 ? "https://${module.gke_cluster[0].endpoint}" : ""
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = var.cloud_provider == "gke" && length(module.gke_cluster) > 0 ? base64decode(module.gke_cluster[0].ca_certificate) : ""
  }
}
