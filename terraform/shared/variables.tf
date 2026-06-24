variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "hcm-hyperfleet"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "hyperfleet-dev-vpc"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.100.0.0/16"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE pods"
  type        = string
  default     = "10.101.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE services"
  type        = string
  default     = "10.102.0.0/16"
}

# =============================================================================
# Lifecycle Enforcer
# =============================================================================
variable "lifecycle_enforcer_dry_run" {
  description = "Run lifecycle enforcer in dry-run mode (logs actions without executing)"
  type        = bool
  default     = true
}

variable "lifecycle_enforcer_schedule" {
  description = "Cron schedule for the lifecycle enforcer (Cloud Scheduler format)"
  type        = string
  default     = "0 * * * *"
}
