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
    Map of Pub/Sub topic configurations. Each topic can have its own set of subscriptions and publishers.

    Example:
      topic_configs = {
        clusters = {
          message_retention_duration = "604800s"
          subscribers = {
            landing-zone = {
              ack_deadline_seconds = 60
            }
            validation-gcp = {
              roles = ["roles/pubsub.subscriber", "roles/pubsub.viewer"]
            }
          }
          publishers = {
            sentinel = {}
          }
        }
        nodepools = {
          subscribers = {
            validation-gcp = {}
          }
          publishers = {
            sentinel = {
              roles = ["roles/pubsub.publisher", "roles/pubsub.viewer"]
            }
          }
        }
      }

    This creates:
    - Topic: {developer}-{ns suffix}-clusters
      - Subscription: {developer}-{ns suffix}-clusters-landing-zone-adapter-sub
      - Subscription: {developer}-{ns suffix}-clusters-validation-gcp-adapter-sub
      - IAM binding for sentinel service account with publisher/viewer roles
    - Topic: {developer}-{ns suffix}-nodepools
      - Subscription: {developer}-{ns suffix}-nodepools-validation-nodepool-gcp-adapter-sub
      - IAM binding for sentinel service account with publisher/viewer roles

    Note: Subscription names include the topic name to ensure uniqueness across the GCP project.
  EOT
  type = map(object({
    message_retention_duration = optional(string, "604800s")
    subscribers = optional(map(object({
      ack_deadline_seconds = optional(number, 60)
      roles                = optional(list(string), ["roles/pubsub.subscriber", "roles/pubsub.viewer"])
    })), {})
    publishers = optional(map(object({
      roles = optional(list(string), ["roles/pubsub.publisher", "roles/pubsub.viewer"])
    })), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for topic_name, topic_config in var.topic_configs :
      alltrue([
        for adapter_name, adapter_config in topic_config.subscribers :
        adapter_config.ack_deadline_seconds >= 10 && adapter_config.ack_deadline_seconds <= 600
      ])
    ])
    error_message = "ack_deadline_seconds must be between 10 and 600 for all subscriptions."
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

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}
