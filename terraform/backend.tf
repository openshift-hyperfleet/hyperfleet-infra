# GCS backend for shared Terraform state with automatic locking
# Usage (required): terraform init -backend-config=<path-to>.tfbackend
# Example: terraform init -backend-config=envs/gke/dev-<your-name>.tfbackend

terraform {
  backend "gcs" {
    # bucket and prefix are set via -backend-config during init
  }
}
