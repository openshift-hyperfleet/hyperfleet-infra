#!/usr/bin/env bash
# Generates Helm override values for HyperFleet components.
#
# For googlepubsub: reads Terraform outputs to build Pub/Sub config.
# For rabbitmq: uses --rabbitmq-url (no Terraform required).
#
# Usage: ./scripts/tf-helm-values.sh [OPTIONS]
#
# Options:
#   --tf-dir DIR          Terraform directory (default: terraform)
#   --out-dir DIR         Output directory for generated files (default: .generated)
#   --broker-type TYPE    Broker type: googlepubsub or rabbitmq (default: googlepubsub)
#   --namespace NS        Kubernetes namespace, used as topic/queue prefix (default: read from Terraform for googlepubsub, required for rabbitmq)
#   --rabbitmq-url URL    RabbitMQ connection URL (required when --broker-type rabbitmq)
#   --adapter-topics STR  Adapter-to-topic mapping as "adapter1=topic,..." (default: adapter1=clusters,adapter2=clusters,adapter3=nodepools)

set -euo pipefail

# Defaults
TF_DIR="terraform"
OUT_DIR=".generated"
BROKER_TYPE="googlepubsub"
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
    --tf-dir)         require_value "$@"; TF_DIR="$2";         shift 2 ;;
    --out-dir)        require_value "$@"; OUT_DIR="$2";        shift 2 ;;
    --broker-type)    require_value "$@"; BROKER_TYPE="$2";    shift 2 ;;
    --namespace)      require_value "$@"; NAMESPACE="$2";      shift 2 ;;
    --rabbitmq-url)   require_value "$@"; RABBITMQ_URL="$2";   shift 2 ;;
    --adapter-topics) require_value "$@"; ADAPTER_TOPICS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

# ── googlepubsub ─────────────────────────────────────────
if [[ "$BROKER_TYPE" == "googlepubsub" ]]; then
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

  # Sentinel values
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

  # Adapter values
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

# ── rabbitmq ─────────────────────────────────────────────
elif [[ "$BROKER_TYPE" == "rabbitmq" ]]; then
  if [[ -z "$RABBITMQ_URL" ]]; then
    echo "ERROR: --rabbitmq-url is required when --broker-type is rabbitmq." >&2
    exit 1
  fi

  NS="${NAMESPACE}"
  if [[ -z "$NS" ]]; then
    echo "ERROR: --namespace is required when --broker-type is rabbitmq." >&2
    exit 1
  fi

  # Redact credentials from URL for logging
  REDACTED_URL=$(echo "$RABBITMQ_URL" | sed 's|//[^@]*@|//***@|')

  echo "Generating RabbitMQ Helm values..."
  echo "  RabbitMQ URL: ${REDACTED_URL}"
  echo "  Namespace:    ${NS}"

  # Sentinel values
  for resource_type in clusters nodepools; do
    file="${OUT_DIR}/sentinel-${resource_type}.yaml"
    cat > "$file" <<EOF
sentinel:
  broker:
    type: rabbitmq
    topic: ${NS}-${resource_type}
    rabbitmq:
      url: "${RABBITMQ_URL}"
      exchangeType: topic
EOF
    echo "  wrote ${file}"
  done

  # Adapter values
  IFS=',' read -ra MAPPINGS <<< "$ADAPTER_TOPICS"
  for mapping in "${MAPPINGS[@]}"; do
    adapter="${mapping%%=*}"
    topic="${mapping##*=}"
    file="${OUT_DIR}/${adapter}.yaml"
    cat > "$file" <<EOF
hyperfleet-adapter:
  broker:
    type: rabbitmq
    rabbitmq:
      url: "${RABBITMQ_URL}"
      queue: ${NS}-${topic}-${adapter}
      exchange: ${NS}-${topic}
      routingKey: "#"
EOF
    echo "  wrote ${file}"
  done

else
  echo "ERROR: unknown broker type '${BROKER_TYPE}'. Supported: googlepubsub, rabbitmq." >&2
  exit 1
fi

echo ""
echo "OK: generated values in ${OUT_DIR}/"
