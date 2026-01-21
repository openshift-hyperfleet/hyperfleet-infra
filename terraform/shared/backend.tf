# GCS backend for shared infrastructure state (VPC, networking)
# Usage (required): terraform init -backend-config=shared.tfbackend

terraform {
  backend "gcs" {
    # bucket and prefix are set via -backend-config during init
  }
}
