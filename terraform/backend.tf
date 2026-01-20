# GCS backend for shared Terraform state with automatic locking
# Usage: terraform init -backend-config=envs/gke/dev-<your-name>.tfbackend

terraform {
  backend "gcs" {
    bucket = "hyperfleet-terraform-state"
    # prefix is set via -backend-config during init
  }
}
