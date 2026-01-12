# =============================================================================
# Cloud Provider Selection
# =============================================================================
variable "cloud_provider" {
  description = "Cloud provider to use: gke, eks, aks"
  type        = string
  default     = "gke"

  validation {
    condition     = contains(["gke", "eks", "aks"], var.cloud_provider)
    error_message = "cloud_provider must be one of: gke, eks, aks"
  }
}

# =============================================================================
# Common Variables
# =============================================================================
variable "developer_name" {
  description = "Developer's username (used in cluster naming)"
  type        = string
}

variable "kubernetes_suffix" {
  description = "Suffix for Kubernetes namespace (allows multiple deployments to share a cluster)"
  type        = string
  default     = "default"
}

# =============================================================================
# Cluster Configuration
# =============================================================================
variable "node_count" {
  description = "Number of nodes in the cluster"
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "Machine/instance type"
  type        = string
  default     = "e2-standard-4"
}

variable "use_spot_vms" {
  description = "Use Spot/Preemptible VMs for cost savings"
  type        = bool
  default     = true
}

# =============================================================================
# GCP-Specific Variables
# =============================================================================
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
  default     = "hcm-hyperfleet"
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "gcp_network" {
  description = "VPC network name (created by shared infra)"
  type        = string
  default     = "hyperfleet-dev-vpc"
}

variable "gcp_subnetwork" {
  description = "VPC subnetwork name (created by shared infra)"
  type        = string
  default     = "hyperfleet-dev-vpc-subnet"
}

# =============================================================================
# AWS-Specific Variables (future)
# =============================================================================
variable "aws_region" {
  description = "AWS region (for future EKS support)"
  type        = string
  default     = "us-east-1"
}

# =============================================================================
# Pub/Sub Configuration
# =============================================================================
variable "kubernetes_namespace" {
  description = "Kubernetes namespace for Workload Identity binding"
  type        = string
  default     = "hyperfleet-system"

  validation {
    condition     = length(var.kubernetes_namespace) > 0
    error_message = "kubernetes_namespace must not be empty."
  }
}

variable "use_pubsub" {
  description = "Use Google Pub/Sub for HyperFleet messaging (instead of RabbitMQ)"
  type        = bool
  default     = false
}

variable "enable_dead_letter" {
  description = "Enable dead letter queue for Pub/Sub"
  type        = bool
  default     = true
}

variable "pubsub_topic_configs" {
  description = <<-EOT
    Pub/Sub topic configurations. Each topic can have its own set of subscriptions and publishers.

    Example:
      pubsub_topic_configs = {
        clusters = {
          subscribers = {
            landing-zone   = {}
            validation-gcp = { ack_deadline_seconds = 120 }
          }
          publishers = {
            sentinel = {}
          }
        }
        nodepools = {
          subscribers = {
            validation-nodepool-gcp = {}
          }
          publishers = {
            sentinel = {}
          }
        }
      }
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
  default = {
    clusters = {
      subscribers = {
        landing-zone   = {}
        validation-gcp = {}
      }
      publishers = {
        sentinel = {}
      }
    }
  }
}
