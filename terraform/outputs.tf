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
# Namespace (used as prefix for Pub/Sub topics, subscriptions, etc.)
# =============================================================================

output "kubernetes_namespace" {
  description = "Kubernetes namespace prefix (developer_name-kubernetes_suffix)"
  value       = local.kubernetes_namespace
}

output "gcp_project_id" {
  description = "GCP project ID used for this deployment"
  value       = var.gcp_project_id
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

output "pubsub_config" {
  description = "Complete Pub/Sub configuration for constructing Helm values (WIF-based)"
  value       = var.use_pubsub ? module.pubsub[0].pubsub_config : null
}

output "pubsub_resources" {
  description = "Complete Pub/Sub resources organized by topic, including subscriptions and publishers"
  value       = var.use_pubsub ? module.pubsub[0].pubsub_resources : null
}

# =============================================================================
# External API Access
# =============================================================================

output "external_api_enabled" {
  description = "Whether external API access is enabled (LoadBalancer firewall rules)"
  value       = var.enable_external_api
}

output "external_api_note" {
  description = "Instructions for external API access"
  value       = var.enable_external_api ? "External API access is ENABLED. Deploy with: helm install hyperfleet charts/hyperfleet-gcp --set base.hyperfleet-api.service.type=LoadBalancer -n hyperfleet-system" : "External API access is DISABLED. Set enable_external_api=true to enable."
}

# =============================================================================
# Helm Values (ready to use with helm install --values)
# =============================================================================

output "helm_values" {
  description = "Helm values for all HyperFleet components (use with terraform output -json helm_values | jq -r '.adapters.adapter1')"
  value = var.use_pubsub ? {
    # Sentinel values (publishers)
    sentinels = {
      for topic_name, topic_data in module.pubsub[0].pubsub_config.topics : topic_name => yamlencode({
        hyperfleet-sentinel = {
          broker = {
            type  = "googlepubsub"
            topic = topic_data.topic_name
            googlepubsub = {
              projectId = var.gcp_project_id
            }
          }
        }
      })
    }

    # Adapter values (subscribers) - organized by subscription key
    adapters = {
      for sub_key, sub_data in module.pubsub[0].pubsub_config.subscriptions : sub_data.adapter_name => yamlencode({
        hyperfleet-adapter = {
          broker = {
            type = "googlepubsub"
            googlepubsub = {
              projectId      = var.gcp_project_id
              subscriptionId = sub_data.subscription_name
              topic          = sub_data.topic_name
            }
          }
        }
      })
    }
  } : null
}