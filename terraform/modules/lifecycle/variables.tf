variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Function and Scheduler"
  type        = string
}

variable "schedule" {
  description = "Cron schedule for the enforcement job (Cloud Scheduler format)"
  type        = string
  default     = "0 * * * *"
}

variable "dry_run" {
  description = "Enable dry-run mode (logs actions without executing them)"
  type        = bool
  default     = true
}

variable "source_dir" {
  description = "Path to the Cloud Function source directory"
  type        = string
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}
