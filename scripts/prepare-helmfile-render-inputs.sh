#!/usr/bin/env bash
# Creates the temporary broker values required by cluster-free Helmfile renders.
# Usage: prepare-helmfile-render-inputs.sh --generated-dir DIR --rabbitmq-namespace NS

set -euo pipefail

generated_dir=""
rabbitmq_namespace=""

require_value() {
    if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: missing value for $1" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --generated-dir)       require_value "$@"; generated_dir="$2";      shift 2 ;;
        --rabbitmq-namespace)  require_value "$@"; rabbitmq_namespace="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$generated_dir" ]]; then
    echo "ERROR: --generated-dir is required" >&2
    exit 1
fi

if [[ -z "$rabbitmq_namespace" ]]; then
    echo "ERROR: --rabbitmq-namespace is required" >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$generated_dir/rabbitmq" "$generated_dir/terraform"

# kind renders read these files. The RabbitMQ namespace must match the
# NAMESPACE used for its render iteration or the Sentinel topics will differ.
"$repo_root/scripts/generate-rabbitmq-values.sh" \
    --out-dir "$generated_dir/rabbitmq" \
    --namespace "$rabbitmq_namespace" \
    --rabbitmq-url amqp://guest:guest@rabbitmq:5672 >/dev/null

for name in adapter1 adapter2 adapter3 sentinel-clusters sentinel-nodepools; do
    printf '%s\n' 'broker: {}' > "$generated_dir/terraform/$name.yaml"
done
