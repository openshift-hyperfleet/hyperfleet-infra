variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "kubernetes_namespace" {
  description = "Kubernetes namespace for Workload Identity binding"
  type        = string
  default     = "hyperfleet-system"
}

variable "developer_name" {
  description = "Developer name to include in resource names for uniqueness"
  type        = string
}

variable "topic_configs" {
  description = <<-EOT
    Map of Pub/Sub topic configurations. Each topic can have its own set of adapter subscriptions.

    Example:
      topic_configs = {
        clusters = {
          message_retention_duration = "604800s"
          adapter_subscriptions = {
            landing-zone = {
              ack_deadline_seconds = 60
            }
            validation-gcp = {}
          }
        }
        nodepools = {
          adapter_subscriptions = {
            validation-gcp = {}
          }
        }
      }

    This creates:
    - Topic: hyperfleet-system-clusters-{developer}
      - Subscription: hyperfleet-system-clusters-landing-zone-adapter-{developer}
      - Subscription: hyperfleet-system-clusters-validation-gcp-adapter-{developer}
    - Topic: hyperfleet-system-nodepools-{developer}
      - Subscription: hyperfleet-system-nodepools-validation-gcp-adapter-{developer}

    Note: Subscription names include the topic name to ensure uniqueness across the GCP project.
  EOT
  type = map(object({
    message_retention_duration = optional(string, "604800s")
    adapter_subscriptions = map(object({
      ack_deadline_seconds = optional(number, 60)
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for topic_name, topic_config in var.topic_configs :
      alltrue([
        for adapter_name, adapter_config in topic_config.adapter_subscriptions :
        adapter_config.ack_deadline_seconds >= 10 && adapter_config.ack_deadline_seconds <= 600
      ])
    ])
    error_message = "ack_deadline_seconds must be between 10 and 600 for all adapter subscriptions."
  }
}

variable "enable_dead_letter" {
  description = "Enable dead letter queue for failed messages"
  type        = bool
  default     = true
}

variable "max_delivery_attempts" {
  description = "Max delivery attempts before sending to DLQ (5-100)"
  type        = number
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 5 && var.max_delivery_attempts <= 100
    error_message = "max_delivery_attempts must be between 5 and 100."
  }
}

variable "sentinel_k8s_sa_name" {
  description = "Kubernetes service account name for Sentinel (shared across all topics)"
  type        = string
  default     = "sentinel"
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}
