#!/usr/bin/env bash
# Generates Helm override values from Terraform outputs.
# Usage: ./scripts/tf-helm-values.sh [OPTIONS]
#
# Options:
#   --tf-dir DIR         Terraform directory (default: terraform)
#   --out-dir DIR        Output directory for generated files (default: .generated)
#   --broker-type TYPE   Broker type (default: googlepubsub)
#   --adapter-topics STR Adapter-to-topic mapping as "adapter1=topic,..." (default: adapter1=clusters,adapter2=clusters,adapter3=nodepools)

set -euo pipefail

# Defaults
TF_DIR="terraform"
OUT_DIR=".generated"
BROKER_TYPE="googlepubsub"
ADAPTER_TOPICS="adapter1=clusters,adapter2=clusters,adapter3=nodepools"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tf-dir)      TF_DIR="$2";       shift 2 ;;
    --out-dir)     OUT_DIR="$2";      shift 2 ;;
    --broker-type) BROKER_TYPE="$2";  shift 2 ;;
    --adapter-topics) ADAPTER_TOPICS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Extract terraform outputs
echo "Reading Terraform outputs from ${TF_DIR}..."
PROJECT_ID=$(cd "$TF_DIR" && terraform output -raw gcp_project_id 2>/dev/null) || true
NS=$(cd "$TF_DIR" && terraform output -raw kubernetes_namespace 2>/dev/null) || true

if [[ -z "$PROJECT_ID" || -z "$NS" ]]; then
  echo "ERROR: could not read terraform outputs (gcp_project_id, kubernetes_namespace)." >&2
  echo "       Run 'make install-terraform' first, or ensure terraform has been applied." >&2
  exit 1
fi

echo "  Project ID: ${PROJECT_ID}"
echo "  Namespace:  ${NS}"

mkdir -p "$OUT_DIR"

# Generate sentinel values
for resource_type in clusters nodepools; do
  file="${OUT_DIR}/sentinel-${resource_type}.yaml"
  cat > "$file" <<EOF
sentinel:
  broker:
    type: ${BROKER_TYPE}
    topic: ${NS}-${resource_type}
    googlepubsub:
      projectId: ${PROJECT_ID}
EOF
  echo "  wrote ${file}"
done

# Generate adapter values
IFS=',' read -ra MAPPINGS <<< "$ADAPTER_TOPICS"
for mapping in "${MAPPINGS[@]}"; do
  adapter="${mapping%%=*}"
  topic="${mapping##*=}"
  file="${OUT_DIR}/${adapter}.yaml"
  cat > "$file" <<EOF
hyperfleet-adapter:
  broker:
    type: ${BROKER_TYPE}
    googlepubsub:
      projectId: ${PROJECT_ID}
      subscriptionId: ${NS}-${topic}-${adapter}
      topic: ${NS}-${topic}
EOF
  echo "  wrote ${file}"
done

echo ""
echo "OK: generated values in ${OUT_DIR}/"
