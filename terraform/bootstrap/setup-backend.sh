#!/usr/bin/env bash
#
# Bootstrap Script: Create GCS Backend for Terraform State
#
# This script creates and configures the GCS bucket used for Terraform remote state.
# Run this ONCE per project before team members start using the remote backend.
#
# Prerequisites:
# - gcloud CLI installed and authenticated
# - Permissions: roles/storage.admin or equivalent on the project
#
# Usage:
#   ./bootstrap/setup-backend.sh
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
PROJECT_ID="hcm-hyperfleet"
BUCKET_NAME="hyperfleet-terraform-state"
REGION="us-central1"
STORAGE_CLASS="STANDARD"

# =============================================================================
# Functions
# =============================================================================
log() {
    echo -e "\033[1;34m==>\033[0m $*"
}

success() {
    echo -e "\033[1;32m✓\033[0m $*"
}

error() {
    echo -e "\033[1;31m✗\033[0m $*" >&2
}

# =============================================================================
# Main
# =============================================================================
log "Setting up Terraform backend for project: $PROJECT_ID"
echo

# Set active project
log "Setting GCP project to: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"
echo

# Check if bucket already exists
if gsutil ls -b "gs://$BUCKET_NAME" &>/dev/null; then
    success "Bucket gs://$BUCKET_NAME already exists"
else
    log "Creating GCS bucket: gs://$BUCKET_NAME"
    gsutil mb \
        -p "$PROJECT_ID" \
        -c "$STORAGE_CLASS" \
        -l "$REGION" \
        "gs://$BUCKET_NAME"
    success "Bucket created successfully"
fi
echo

# Enable versioning for disaster recovery
log "Enabling versioning on bucket (allows state recovery)"
gsutil versioning set on "gs://$BUCKET_NAME"
success "Versioning enabled"
echo

# Enable uniform bucket-level access for better security
log "Enabling uniform bucket-level access"
gsutil uniformbucketlevelaccess set on "gs://$BUCKET_NAME"
success "Uniform bucket-level access enabled"
echo

# Grant object-level permissions to project owners and editors
# Required because uniform bucket-level access disables legacy ACLs
# and legacyBucketOwner/legacyBucketReader don't include object permissions
log "Granting storage.objectAdmin to project owners and editors"

# Get current IAM policy
gsutil iam get "gs://$BUCKET_NAME" > /tmp/bucket-iam-policy.json

# Create new IAM policy with object-level permissions for project groups
cat > /tmp/bucket-iam-policy.json <<EOF
{
  "bindings": [
    {
      "role": "roles/storage.legacyBucketOwner",
      "members": [
        "projectOwner:$PROJECT_ID"
      ]
    },
    {
      "role": "roles/storage.legacyBucketReader",
      "members": [
        "projectViewer:$PROJECT_ID"
      ]
    },
    {
      "role": "roles/storage.objectAdmin",
      "members": [
        "projectOwner:$PROJECT_ID",
        "projectEditor:$PROJECT_ID"
      ]
    }
  ]
}
EOF

# Set the IAM policy
gsutil iam set /tmp/bucket-iam-policy.json "gs://$BUCKET_NAME"
rm /tmp/bucket-iam-policy.json
success "IAM permissions granted to project owners and editors"
echo

# Set lifecycle policy to clean up old versions after 90 days
log "Setting lifecycle policy (delete non-current versions after 90 days)"
cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {
          "type": "Delete"
        },
        "condition": {
          "numNewerVersions": 3,
          "isLive": false
        }
      }
    ]
  }
}
EOF

gsutil lifecycle set /tmp/lifecycle.json "gs://$BUCKET_NAME"
rm /tmp/lifecycle.json
success "Lifecycle policy configured"
echo

# Display bucket info
log "Bucket configuration:"
gsutil ls -L -b "gs://$BUCKET_NAME" | grep -E "(Location|Storage class|Versioning|Bucket Policy Only)"
echo

success "Backend setup complete!"
echo
echo "Next steps:"
echo "  1. Grant team members IAM permissions (see terraform/BACKEND.md)"
echo "  2. Initialize Terraform with the backend:"
echo "     cd terraform"
echo "     terraform init -backend-config=\"prefix=terraform/state/dev-<your-name>\""
echo
echo "For shared environments (e.g., Prow cluster):"
echo "     terraform init -backend-config=envs/gke/dev-prow.tfbackend"
echo
