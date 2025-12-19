# =============================================================================
# Sentinel Service Account (Publisher)
# =============================================================================


resource "google_pubsub_topic_iam_member" "sentinel_publisher_wif" {
  topic     = google_pubsub_topic.events.name
  role      = "roles/pubsub.publisher"
  member    = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.sentinel_k8s_sa_name}"
  project   = var.project_id
}

# Workload Identity binding for Sentinel

# =============================================================================
# Adapter Service Account (Subscriber)
# =============================================================================

# Grant Adapter permission to subscribe to the adapter subscription
resource "google_pubsub_subscription_iam_member" "adapter_subscriber" {
  subscription = google_pubsub_subscription.adapter.name
  role         = "roles/pubsub.subscriber"
  member    = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.adapter_k8s_sa_name}"
  project      = var.project_id
}

# Grant Adapter permission to view subscription (needed for some operations)
resource "google_pubsub_subscription_iam_member" "adapter_viewer" {
  subscription = google_pubsub_subscription.adapter.name
  role         = "roles/pubsub.viewer"
  member    = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.adapter_k8s_sa_name}"
  project      = var.project_id
}


# =============================================================================
# Dead Letter Queue Permissions (if enabled)
# =============================================================================

# Grant Pub/Sub service account permission to publish to DLQ
# This is required for the dead letter policy to work
resource "google_pubsub_topic_iam_member" "pubsub_dlq_publisher" {
  count   = var.enable_dead_letter ? 1 : 0
  topic   = google_pubsub_topic.dead_letter[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  project = var.project_id
}

# Grant Pub/Sub service account permission to acknowledge messages from main subscription
resource "google_pubsub_subscription_iam_member" "pubsub_dlq_subscriber" {
  count        = var.enable_dead_letter ? 1 : 0
  subscription = google_pubsub_subscription.adapter.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  project      = var.project_id
}

# Get current project info for Pub/Sub service account
data "google_project" "current" {
  project_id = var.project_id
}
