# =============================================================================
# Sentinel Service Account (Publisher)
# =============================================================================
resource "google_service_account" "sentinel" {
  account_id   = var.sentinel_sa_name
  display_name = "HyperFleet Sentinel"
  description  = "Service account for HyperFleet Sentinel to publish events to Pub/Sub"
  project      = var.project_id
}

# Grant Sentinel permission to publish to the events topic
resource "google_pubsub_topic_iam_member" "sentinel_publisher" {
  topic   = google_pubsub_topic.events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sentinel.email}"
  project = var.project_id
}

# Workload Identity binding for Sentinel
# Allows the Kubernetes service account to impersonate the GCP service account
resource "google_service_account_iam_member" "sentinel_workload_identity" {
  service_account_id = google_service_account.sentinel.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.sentinel_k8s_sa_name}]"
}

# =============================================================================
# Adapter Service Account (Subscriber)
# =============================================================================
resource "google_service_account" "adapter" {
  account_id   = var.adapter_sa_name
  display_name = "HyperFleet Adapter"
  description  = "Service account for HyperFleet Adapter to consume events from Pub/Sub"
  project      = var.project_id
}

# Grant Adapter permission to subscribe to the adapter subscription
resource "google_pubsub_subscription_iam_member" "adapter_subscriber" {
  subscription = google_pubsub_subscription.adapter.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.adapter.email}"
  project      = var.project_id
}

# Grant Adapter permission to view subscription (needed for some operations)
resource "google_pubsub_subscription_iam_member" "adapter_viewer" {
  subscription = google_pubsub_subscription.adapter.name
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${google_service_account.adapter.email}"
  project      = var.project_id
}

# Workload Identity binding for Adapter
resource "google_service_account_iam_member" "adapter_workload_identity" {
  service_account_id = google_service_account.adapter.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.adapter_k8s_sa_name}]"
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
