# =============================================================================
# Sentinel Workload Identity (Publisher) - Publishes to all topics
# =============================================================================
# Grant Sentinel permission to publish to all topics using WIF principal
resource "google_pubsub_topic_iam_member" "sentinel_publisher" {
  for_each = local.topics

  topic   = google_pubsub_topic.topics[each.key].name
  role    = "roles/pubsub.publisher"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.kubernetes_namespace}/sa/${var.sentinel_k8s_sa_name}"
  project = var.project_id
}

# Grant Sentinel permission to view all topics metadata (needed to check if topic exists)
resource "google_pubsub_topic_iam_member" "sentinel_viewer" {
  for_each = local.topics

  topic   = google_pubsub_topic.topics[each.key].name
  role    = "roles/pubsub.viewer"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.kubernetes_namespace}/sa/${var.sentinel_k8s_sa_name}"
  project = var.project_id
}

# =============================================================================
# Adapter Workload Identity (Subscribers)
# =============================================================================
# Grant Adapter permission to subscribe to their subscriptions using WIF principals
resource "google_pubsub_subscription_iam_member" "adapters_subscriber" {
  for_each = local.all_subscriptions

  subscription = google_pubsub_subscription.subscriptions[each.key].name
  role         = "roles/pubsub.subscriber"
  member       = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.kubernetes_namespace}/sa/${each.value.adapter_name}-adapter"
  project      = var.project_id
}

# Grant Adapter permission to view subscriptions (needed for some operations)
resource "google_pubsub_subscription_iam_member" "adapters_viewer" {
  for_each = local.all_subscriptions

  subscription = google_pubsub_subscription.subscriptions[each.key].name
  role         = "roles/pubsub.viewer"
  member       = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.kubernetes_namespace}/sa/${each.value.adapter_name}-adapter"
  project      = var.project_id
}

# =============================================================================
# Dead Letter Queue Permissions (if enabled)
# =============================================================================

# Grant Pub/Sub service account permission to publish to DLQ topics
# This is required for the dead letter policy to work
resource "google_pubsub_topic_iam_member" "pubsub_dlq_publisher" {
  for_each = var.enable_dead_letter ? local.topics : {}

  topic   = google_pubsub_topic.dead_letter[each.key].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  project = var.project_id
}

# Grant Pub/Sub service account permission to acknowledge messages from all subscriptions
resource "google_pubsub_subscription_iam_member" "pubsub_dlq_subscriber" {
  for_each = var.enable_dead_letter ? local.all_subscriptions : {}

  subscription = google_pubsub_subscription.subscriptions[each.key].name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  project      = var.project_id
}

# Get current project info for service account references
data "google_project" "current" {
  project_id = var.project_id
}
