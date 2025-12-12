# =============================================================================
# Unified Cluster Outputs (cloud-agnostic)
# =============================================================================

output "cluster_name" {
  description = "Name of the created cluster"
  value = (
    var.cloud_provider == "gke" ? module.gke_cluster[0].cluster_name :
    "unknown"
  )
}

output "cluster_endpoint" {
  description = "Cluster API endpoint"
  value = (
    var.cloud_provider == "gke" ? module.gke_cluster[0].endpoint :
    "unknown"
  )
  sensitive = true
}

output "cluster_ca_certificate" {
  description = "Cluster CA certificate (base64 encoded)"
  value = (
    var.cloud_provider == "gke" ? module.gke_cluster[0].ca_certificate :
    "unknown"
  )
  sensitive = true
}

output "cluster_location" {
  description = "Cluster location (zone or region)"
  value = (
    var.cloud_provider == "gke" ? module.gke_cluster[0].location :
    "unknown"
  )
}

# =============================================================================
# Connection Instructions
# =============================================================================

output "connect_command" {
  description = "Command to configure kubectl"
  value = (
    var.cloud_provider == "gke" ?
    "gcloud container clusters get-credentials ${module.gke_cluster[0].cluster_name} --zone ${module.gke_cluster[0].location} --project ${var.gcp_project_id}" :
    "# Connection command not available for ${var.cloud_provider}"
  )
}

# =============================================================================
# Pub/Sub Outputs (when enabled)
# =============================================================================

output "sentinel_service_account_email" {
  description = "Email of the Sentinel GCP service account"
  value       = var.enable_pubsub ? module.pubsub[0].sentinel_service_account_email : ""
}

output "adapter_service_account_email" {
  description = "Email of the Adapter GCP service account"
  value       = var.enable_pubsub ? module.pubsub[0].adapter_service_account_email : ""
}

output "topic_name" {
  description = "Name of the Pub/Sub topic"
  value       = var.enable_pubsub ? module.pubsub[0].topic_name : ""
}

output "subscription_name" {
  description = "Name of the Pub/Sub subscription"
  value       = var.enable_pubsub ? module.pubsub[0].subscription_name : ""
}

output "helm_values_snippet" {
  description = "Snippet to add to Helm values for Workload Identity annotations"
  value       = var.enable_pubsub ? module.pubsub[0].helm_values_snippet : ""
}
