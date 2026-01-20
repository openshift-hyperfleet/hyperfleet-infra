# GCS backend for shared infrastructure state (VPC, networking)
# Usage: terraform init -backend-config=shared.tfbackend

terraform {
  backend "gcs" {
    bucket = "hyperfleet-terraform-state"
    # prefix is set via shared.tfbackend
  }
}
