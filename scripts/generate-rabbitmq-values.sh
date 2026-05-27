#!/usr/bin/env bash
# Generates Helm override values for RabbitMQ deployments
#
# For Google Pub/Sub: Terraform automatically generates files via local_file resources.
# For RabbitMQ: Use this script to generate values based on RabbitMQ URL.
#
# Usage: ./scripts/generate-rabbitmq-values.sh --rabbitmq-url <URL> --namespace <NS> [OPTIONS]
#
# Options:
#   --out-dir DIR         Output directory for generated files (default: generated-values-rabbitmq)
#   --namespace NS        Kubernetes namespace, used as topic/queue prefix (required)
#   --rabbitmq-url URL    RabbitMQ connection URL (required)
#   --adapter-topics STR  Adapter-to-topic mapping as "adapter1=topic,..." (default: adapter1=clusters,adapter2=clusters,adapter3=nodepools)

set -euo pipefail

# Defaults
OUT_DIR="generated-values-rabbitmq"
ADAPTER_TOPICS="adapter1=clusters,adapter2=clusters,adapter3=nodepools"
RABBITMQ_URL=""
NAMESPACE=""

require_value() {
  if [[ $# -lt 2 || "$2" == --* ]]; then
    echo "ERROR: missing value for $1" >&2; exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)        require_value "$@"; OUT_DIR="$2";        shift 2 ;;
    --namespace)      require_value "$@"; NAMESPACE="$2";      shift 2 ;;
    --rabbitmq-url)   require_value "$@"; RABBITMQ_URL="$2";   shift 2 ;;
    --adapter-topics) require_value "$@"; ADAPTER_TOPICS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$RABBITMQ_URL" ]]; then
  echo "ERROR: --rabbitmq-url is required" >&2
  exit 1
fi

if [[ -z "$NAMESPACE" ]]; then
  echo "ERROR: --namespace is required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# Redact credentials from URL for logging
# shellcheck disable=SC2001
REDACTED_URL=$(echo "$RABBITMQ_URL" | sed 's|//[^@]*@|//***@|')

echo "Generating RabbitMQ Helm values..."
echo "  RabbitMQ URL: ${REDACTED_URL}"
echo "  Namespace:    ${NAMESPACE}"

# Sentinel values
for resource_type in clusters nodepools; do
  file="${OUT_DIR}/sentinel-${resource_type}.yaml"
  cat > "$file" <<EOF
broker:
  type: rabbitmq
  topic: ${NAMESPACE}-${resource_type}
  rabbitmq:
    url: "${RABBITMQ_URL}"
    exchangeType: topic
EOF
  echo "  ✓ ${file}"
done

# Adapter values
IFS=',' read -ra MAPPINGS <<< "$ADAPTER_TOPICS"
for mapping in "${MAPPINGS[@]}"; do
  adapter="${mapping%%=*}"
  topic="${mapping##*=}"
  file="${OUT_DIR}/${adapter}.yaml"
  cat > "$file" <<EOF
broker:
  type: rabbitmq
  rabbitmq:
    url: "${RABBITMQ_URL}"
    queue: ${NAMESPACE}-${topic}-${adapter}
    exchange: ${NAMESPACE}-${topic}
    routingKey: "#"
EOF
  echo "  ✓ ${file}"
done

echo ""
echo "INFO: Generated RabbitMQ values in ${OUT_DIR}/"
