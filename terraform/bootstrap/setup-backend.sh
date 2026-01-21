#!/usr/bin/env bash
#
# Bootstrap Script: Create GCS Backend for Terraform State
#
# This script creates and configures the GCS bucket used for Terraform remote state.
# Run this ONCE per project before team members start using the remote backend.
#
# Prerequisites:
# - gcloud CLI installed and authenticated
# - jq installed (for IAM policy merging)
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

# Prints an informational message with blue arrow prefix
# Arguments:
#   $* - Message text to display
log() {
    echo -e "\033[1;34m==>\033[0m $*"
}

# Prints a success message with green checkmark prefix
# Arguments:
#   $* - Success message text to display
success() {
    echo -e "\033[1;32m✓\033[0m $*"
}

# Prints an error message with red X prefix to stderr
# Arguments:
#   $* - Error message text to display
error() {
    echo -e "\033[1;31m✗\033[0m $*" >&2
}

# =============================================================================
# Main
# =============================================================================
log "Setting up Terraform backend for project: $PROJECT_ID"
echo

# Check dependencies
log "Checking dependencies"
if ! command -v gcloud &>/dev/null; then
    error "gcloud CLI is not installed or not in PATH"
    echo "  Install from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    error "jq is not installed or not in PATH"
    echo "  Install from: https://jqlang.github.io/jq/download/"
    exit 1
fi
success "All dependencies found"
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
log "Granting IAM permissions to project owners, editors, and viewers"

# Note: gsutil iam ch doesn't support project convenience groups (projectOwner, etc.)
# with legacy roles, so we must use gsutil iam set. To avoid overwriting existing
# bindings, we fetch the current policy, merge our bindings, then set it back.

# Fetch current IAM policy
CURRENT_POLICY=$(gsutil iam get "gs://$BUCKET_NAME")

# Required bindings for Terraform state management
REQUIRED_BINDINGS='[
  {
    "role": "roles/storage.legacyBucketOwner",
    "members": ["projectOwner:'$PROJECT_ID'"]
  },
  {
    "role": "roles/storage.legacyBucketReader",
    "members": ["projectViewer:'$PROJECT_ID'"]
  },
  {
    "role": "roles/storage.objectAdmin",
    "members": ["projectOwner:'$PROJECT_ID'", "projectEditor:'$PROJECT_ID'"]
  }
]'

# Merge current policy with required bindings using jq
# This preserves existing bindings and adds/updates only what we need
MERGED_POLICY=$(echo "$CURRENT_POLICY" | jq --argjson required "$REQUIRED_BINDINGS" '
  # Process each required binding while preserving top-level metadata (etag, version)
  reduce $required[] as $req (
    .;

    # Find if this role already exists
    (.bindings | map(.role == $req.role) | index(true)) as $idx |

    if $idx then
      # Role exists - merge members (union to avoid duplicates)
      .bindings[$idx].members |= (. + $req.members | unique)
    else
      # Role does not exist - add it
      .bindings += [$req]
    end
  )
')

# Apply the merged policy
echo "$MERGED_POLICY" | gsutil iam set /dev/stdin "gs://$BUCKET_NAME"

success "IAM permissions granted to project owners and editors"
echo

# Set lifecycle policy to clean up old versions
# Keeps the 5 most recent versions OR deletes versions older than 90 days
log "Setting lifecycle policy: keep last 5 versions OR delete non-live versions older than 90 days"
cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {
          "type": "Delete"
        },
        "condition": {
          "numNewerVersions": 5,
          "isLive": false
        }
      },
      {
        "action": {
          "type": "Delete"
        },
        "condition": {
          "daysSinceNoncurrentTime": 90,
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
echo "  1. Grant individual team members IAM permissions for GCP resources"
echo "     (see terraform/README.md#team-member-setup)"
echo "     Note: Project owners/editors already have bucket access"
echo "  2. Create your backend configuration file:"
echo "     cd terraform"
echo "     cp envs/gke/dev.tfbackend.example envs/gke/dev-<your-name>.tfbackend"
echo "     # Edit dev-<your-name>.tfbackend to set your prefix"
echo "  3. Initialize Terraform with the backend:"
echo "     terraform init -backend-config=envs/gke/dev-<your-name>.tfbackend"
echo
echo "For shared environments (e.g., Prow cluster):"
echo "     terraform init -backend-config=envs/gke/dev-prow.tfbackend"
echo
