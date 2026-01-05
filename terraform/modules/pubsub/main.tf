locals {
  # Flatten topic configs into a map of topics
  # Key: topic name, Value: topic configuration with full topic name
  topics = {
    for topic_name, topic_config in var.topic_configs : topic_name => {
      full_topic_name            = "${var.kubernetes_namespace}-${topic_name}"
      dlq_topic_name             = "${var.kubernetes_namespace}-${topic_name}-dlq"
      message_retention_duration = topic_config.message_retention_duration
      adapter_subscriptions      = topic_config.adapter_subscriptions
    }
  }

  # Flatten all subscriptions across all topics into a single map
  # Key: "{topic_name}-{adapter_name}", Value: subscription configuration
  all_subscriptions = merge([
    for topic_name, topic_config in local.topics : {
      for adapter_name, adapter_config in topic_config.adapter_subscriptions :
      "${topic_name}-${adapter_name}" => {
        subscription_name    = "${var.kubernetes_namespace}-${topic_name}-${adapter_name}-adapter"
        adapter_name         = adapter_name
        topic_name           = topic_name
        ack_deadline_seconds = adapter_config.ack_deadline_seconds
      }
    }
  ]...)

  # Get unique adapter names across all topics for service account creation
  unique_adapters = toset(flatten([
    for topic_name, topic_config in var.topic_configs :
    keys(topic_config.adapter_subscriptions)
  ]))

  common_labels = merge(var.labels, {
    managed-by = "terraform"
    component  = "hyperfleet-pubsub"
  })
}

# =============================================================================
# Pub/Sub Topics
# =============================================================================
resource "google_pubsub_topic" "topics" {
  for_each = local.topics

  name    = each.value.full_topic_name
  project = var.project_id

  # Retain messages for replay (optional)
  message_retention_duration = each.value.message_retention_duration

  labels = local.common_labels
}

# =============================================================================
# Dead Letter Topics (for failed messages)
# =============================================================================
resource "google_pubsub_topic" "dead_letter" {
  for_each = var.enable_dead_letter ? local.topics : {}

  name    = each.value.dlq_topic_name
  project = var.project_id

  labels = local.common_labels
}

# =============================================================================
# Pub/Sub Subscriptions for Adapters
# =============================================================================
resource "google_pubsub_subscription" "subscriptions" {
  for_each = local.all_subscriptions

  name    = each.value.subscription_name
  topic   = google_pubsub_topic.topics[each.value.topic_name].name
  project = var.project_id

  # ACK deadline (how long adapter has to acknowledge)
  ack_deadline_seconds = each.value.ack_deadline_seconds

  # Message retention (how long to keep unacked messages)
  message_retention_duration = local.topics[each.value.topic_name].message_retention_duration

  # Don't auto-delete subscription
  expiration_policy {
    ttl = ""
  }

  # Dead letter policy
  dynamic "dead_letter_policy" {
    for_each = var.enable_dead_letter ? [1] : []
    content {
      dead_letter_topic     = google_pubsub_topic.dead_letter[each.value.topic_name].id
      max_delivery_attempts = var.max_delivery_attempts
    }
  }

  # Retry policy
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  labels = local.common_labels
}

# =============================================================================
# Dead Letter Subscriptions (for monitoring failed messages)
# =============================================================================
resource "google_pubsub_subscription" "dead_letter" {
  for_each = var.enable_dead_letter ? local.topics : {}

  name    = "${each.value.dlq_topic_name}-sub"
  topic   = google_pubsub_topic.dead_letter[each.key].name
  project = var.project_id

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 days

  expiration_policy {
    ttl = ""
  }

  labels = local.common_labels
}
