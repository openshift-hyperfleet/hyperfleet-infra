# =============================================================================
# Topic Outputs
# =============================================================================
output "topic_name" {
  description = "Name of the Pub/Sub topic"
  value       = google_pubsub_topic.events.name
}

output "topic_id" {
  description = "Full ID of the Pub/Sub topic"
  value       = google_pubsub_topic.events.id
}

output "dlq_topic_name" {
  description = "Name of the dead letter topic (null when DLQ is disabled)"
  value       = var.enable_dead_letter ? google_pubsub_topic.dead_letter[0].name : null
}

# =============================================================================
# Subscription Outputs
# =============================================================================
output "subscription_name" {
  description = "Name of the Pub/Sub subscription"
  value       = google_pubsub_subscription.adapter.name
}

output "subscription_id" {
  description = "Full ID of the Pub/Sub subscription"
  value       = google_pubsub_subscription.adapter.id
}

# =============================================================================
# Service Account Outputs
# =============================================================================
output "sentinel_service_account_email" {
  description = "Email of the Sentinel GCP service account"
  value       = google_service_account.sentinel.email
}

output "adapter_service_account_email" {
  description = "Email of the Adapter GCP service account"
  value       = google_service_account.adapter.email
}

# =============================================================================
# Helm Values Snippet
# =============================================================================
output "helm_values_snippet" {
  description = "Snippet to add to Helm values for Workload Identity annotations"
  value       = <<-EOT
    # Add these annotations to your Helm values:

    # For Sentinel:
    sentinel:
      serviceAccount:
        annotations:
          iam.gke.io/gcp-service-account: ${google_service_account.sentinel.email}
      broker:
        type: googlepubsub
        topic: ${google_pubsub_topic.events.name}
        googlepubsub:
          projectId: ${var.project_id}
          createTopicIfMissing: false

    # For Adapter:
    hyperfleet-adapter:
      serviceAccount:
        annotations:
          iam.gke.io/gcp-service-account: ${google_service_account.adapter.email}
      broker:
        type: googlepubsub
        subscriptionId: ${google_pubsub_subscription.adapter.name}
        topic: ${google_pubsub_topic.events.name}
        googlepubsub:
          projectId: ${var.project_id}
          createSubscriptionIfMissing: false
  EOT
}
