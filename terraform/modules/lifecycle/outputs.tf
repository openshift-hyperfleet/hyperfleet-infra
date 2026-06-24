output "function_uri" {
  description = "URI of the deployed Cloud Function"
  value       = google_cloudfunctions2_function.enforcer.service_config[0].uri
}

output "scheduler_job_name" {
  description = "Name of the Cloud Scheduler job"
  value       = google_cloud_scheduler_job.enforcer.name
}

output "function_service_account" {
  description = "Email of the Cloud Function service account"
  value       = google_service_account.function.email
}
