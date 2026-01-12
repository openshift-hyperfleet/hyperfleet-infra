# =============================================================================
# Pub/Sub Resources Output (Hierarchical)
# =============================================================================
output "pubsub_resources" {
  description = "Complete Pub/Sub resources organized by topic, including subscriptions and publishers"
  value = {
    for topic_name, topic_config in local.topics : topic_name => {
      topic_name     = google_pubsub_topic.topics[topic_name].name
      topic_id       = google_pubsub_topic.topics[topic_name].id
      dlq_topic_name = var.enable_dead_letter ? google_pubsub_topic.dead_letter[topic_name].name : null

      subscribers = {
        for adapter_name, adapter_config in topic_config.subscribers :
        adapter_name => {
          name                 = google_pubsub_subscription.subscriptions["${topic_name}-${adapter_name}"].name
          id                   = google_pubsub_subscription.subscriptions["${topic_name}-${adapter_name}"].id
          ack_deadline_seconds = adapter_config.ack_deadline_seconds
          service_account      = "${adapter_name}-adapter"
          roles                = adapter_config.roles
        }
      }

      publishers = {
        for publisher_name, publisher_config in topic_config.publishers :
        publisher_name => {
          service_account = publisher_name
          roles           = publisher_config.roles
        }
      }
    }
  }
}

# =============================================================================
# Helm Values Snippet
# =============================================================================
output "helm_values_snippet" {
  description = "Snippet to add to Helm values for Workload Identity and Pub/Sub configuration"
  value       = <<-EOT
%{for topic_name, topic_config in local.topics~}
# ============================================================================
# Services for ${replace(title(replace(topic_name, "-", " ")), " ", " ")} Topic
# Topic name: ${google_pubsub_topic.topics[topic_name].name}
# DLQ topic name: ${var.enable_dead_letter ? google_pubsub_topic.dead_letter[topic_name].name : "N/A (DLQ disabled)"}
# ============================================================================
# Publishers (publish to ${topic_name} topic)
%{for publisher_name, publisher_config in topic_config.publishers~}
${topic_name}-${publisher_name}:
  serviceAccount:
    name: ${publisher_name}
  broker:
    type: googlepubsub
    topic: ${google_pubsub_topic.topics[topic_name].name}
    googlepubsub:
      projectId: ${var.project_id}

%{endfor~}
# Adapters (subscribe to ${topic_name} topic)
%{for adapter_name, adapter_config in topic_config.subscribers~}
${topic_name}-${adapter_name}-adapter:
  serviceAccount:
    name: ${adapter_name}-adapter
  broker:
    type: googlepubsub
    googlepubsub:
      projectId: ${var.project_id}
      topic: ${google_pubsub_topic.topics[topic_name].name}
      subscription: ${google_pubsub_subscription.subscriptions["${topic_name}-${adapter_name}"].name}
%{if var.enable_dead_letter~}
      deadLetterTopic: ${google_pubsub_topic.dead_letter[topic_name].name}
%{endif~}

%{endfor~}
%{endfor~}
  EOT
}
