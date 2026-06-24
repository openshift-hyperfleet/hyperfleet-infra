locals {
  function_name = "lifecycle-enforcer"
  bucket_name   = "${var.project_id}-lifecycle-enforcer-src"
}

# =============================================================================
# GCS Bucket for Cloud Function source code
# =============================================================================
resource "google_storage_bucket" "function_source" {
  name                        = local.bucket_name
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  labels = var.labels
}

data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.tmp/function-source.zip"
}

resource "google_storage_bucket_object" "function_source" {
  name   = "function-source-${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_source.output_path
}

# =============================================================================
# Service Accounts
# =============================================================================
resource "google_service_account" "function" {
  account_id   = "lifecycle-enforcer-fn"
  display_name = "Lifecycle Enforcer Cloud Function"
  project      = var.project_id
}

resource "google_service_account" "scheduler" {
  account_id   = "lifecycle-enforcer-sched"
  display_name = "Lifecycle Enforcer Cloud Scheduler"
  project      = var.project_id
}

# =============================================================================
# IAM Bindings — Cloud Function service account
# =============================================================================
resource "google_project_iam_member" "function_container_admin" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.function.email}"
}

resource "google_project_iam_member" "function_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.function.email}"
}

# =============================================================================
# IAM Bindings — Cloud Scheduler invokes the Cloud Function
# =============================================================================
resource "google_cloud_run_v2_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.enforcer.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

# =============================================================================
# Cloud Function Gen2
# =============================================================================
resource "google_cloudfunctions2_function" "enforcer" {
  name     = local.function_name
  location = var.region
  project  = var.project_id

  build_config {
    runtime     = "go125"
    entry_point = "EnforceLifecycle"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    timeout_seconds    = 300
    available_memory   = "256Mi"

    service_account_email = google_service_account.function.email

    environment_variables = {
      PROJECT_ID = var.project_id
      DRY_RUN    = var.dry_run ? "true" : "false"
    }
  }

  labels = var.labels
}

# =============================================================================
# Cloud Scheduler
# =============================================================================
resource "google_cloud_scheduler_job" "enforcer" {
  name      = "${local.function_name}-trigger"
  schedule  = var.schedule
  time_zone = "UTC"
  project   = var.project_id
  region    = var.region

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.enforcer.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.scheduler.email
    }
  }
}
