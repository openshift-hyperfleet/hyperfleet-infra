variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for Workload Identity binding"
  type        = string
  default     = "hyperfleet-system"
}

variable "resource_type" {
  description = "Resource type for topic naming (e.g., clusters, nodepools)"
  type        = string
  default     = "clusters"
}

variable "topic_name" {
  description = "Override topic name (default: {namespace}-{resource_type})"
  type        = string
  default     = ""
}

variable "subscription_name" {
  description = "Override subscription name (default: {namespace}-adapter)"
  type        = string
  default     = ""
}

variable "message_retention_duration" {
  description = "How long to retain unacknowledged messages (default: 7 days)"
  type        = string
  default     = "604800s"
}

variable "ack_deadline_seconds" {
  description = "ACK deadline for subscription (10-600 seconds)"
  type        = number
  default     = 60

  validation {
    condition     = var.ack_deadline_seconds >= 10 && var.ack_deadline_seconds <= 600
    error_message = "ack_deadline_seconds must be between 10 and 600."
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

variable "sentinel_sa_name" {
  description = "Sentinel GCP service account name"
  type        = string
  default     = "hyperfleet-sentinel"
}

variable "adapter_sa_name" {
  description = "Adapter GCP service account name"
  type        = string
  default     = "hyperfleet-adapter"
}

variable "sentinel_k8s_sa_name" {
  description = "Sentinel Kubernetes service account name"
  type        = string
  default     = "sentinel"
}

variable "adapter_k8s_sa_name" {
  description = "Adapter Kubernetes service account name"
  type        = string
  default     = "hyperfleet-adapter"
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}
