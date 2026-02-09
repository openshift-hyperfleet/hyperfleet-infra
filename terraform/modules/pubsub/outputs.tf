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
# Pub/Sub Configuration Output (Complete Data for Helm Values)
# =============================================================================
# This output provides ALL Pub/Sub configuration data needed to construct
# Helm values for any deployment scenario (single or multi-topic).
#
# With WIF (Workload Identity Federation), Kubernetes service accounts are
# granted permissions directly via WIF principals. No GCP service accounts
# are created.
#
# Example usage:
#   terraform output -json pubsub_config | jq '.topics.clusters.topic_name'
#   terraform output -json pubsub_config | jq '.subscriptions["clusters-adapter1"]'

output "pubsub_config" {
  description = "Complete Pub/Sub configuration for constructing Helm values (WIF-based)"
  value = {
    # GCP Project
    project_id = var.project_id

    # Kubernetes namespace (used in WIF principal)
    kubernetes_namespace = var.kubernetes_namespace

    # All topics with their publishers
    topics = {
      for topic_name, topic_config in local.topics : topic_name => {
        topic_name     = google_pubsub_topic.topics[topic_name].name
        topic_id       = google_pubsub_topic.topics[topic_name].id
        dlq_topic_name = var.enable_dead_letter ? google_pubsub_topic.dead_letter[topic_name].name : null
        resource_type  = topic_name # clusters, nodepools, etc.

        # Publishers for this topic (with their K8s SA names)
        publishers = {
          for publisher_name, publisher_config in topic_config.publishers :
          publisher_name => {
            k8s_service_account = publisher_name
            roles               = publisher_config.roles
          }
        }
      }
    }

    # All subscriptions indexed by "{topic}-{adapter}" key
    subscriptions = {
      for key, sub in local.all_subscriptions : key => {
        subscription_name = google_pubsub_subscription.subscriptions[key].name
        subscription_id   = google_pubsub_subscription.subscriptions[key].id
        topic_name        = google_pubsub_topic.topics[sub.topic_name].name
        dlq_topic_name    = var.enable_dead_letter ? google_pubsub_topic.dead_letter[sub.topic_name].name : null
        adapter_name      = sub.adapter_name
        k8s_service_account = "${sub.adapter_name}-adapter"
        ack_deadline      = sub.ack_deadline_seconds
        roles             = sub.roles
      }
    }
  }
}
