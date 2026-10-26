#!/usr/bin/env bash
# Render the real API/Sentinel charts, then parse and assert their configuration
# with a test-only Helm chart. No deployment or live Kubernetes access is needed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/rabbitmq" "$work/terraform"

# API auth rendering discovers the Kubernetes issuer. Stub only that read;
# reject all other kubectl calls so this test cannot touch the active cluster.
cat > "$work/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
if [[ "$*" == "get --raw=/.well-known/openid-configuration" ]]; then
    echo '{"issuer":"https://kubernetes.invalid","jwks_uri":"https://kubernetes.invalid/keys"}'
else
    echo "ERROR: unexpected kubectl call: $*" >&2
    exit 1
fi
KUBECTL
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
export AUTH_MODE=API OIDC_ISSUER_MODE=external OIDC_ISSUER_URL='' OIDC_JWKS_URL=''
export TENANT_ISOLATION_ENABLED=false OBSERVABILITY_ENABLED=false TRACING_ENABLED=false
export EXTERNAL_DNS_ENABLED=false
namespace_prefix=hf-fixtures
scripts/prepare-helmfile-render-inputs.sh --generated-dir "$work" \
    --rabbitmq-namespace "${namespace_prefix}-kind"
export GENERATED_RABBITMQ_DIR="$work/rabbitmq" GENERATED_DIR="$work/terraform"

state=(-f helmfile/helmfile.yaml.gotmpl)
selected=(-l component=api -l component=sentinel -l component=gateway)
export NAMESPACE="$namespace_prefix" RUN_ID="$namespace_prefix"
helmfile "${state[@]}" -e e2e-kind repos >/dev/null
for environment in e2e-kind e2e-gcp kind gcp; do
    export NAMESPACE="${namespace_prefix}-${environment}" RUN_ID="${namespace_prefix}-${environment}"
    helmfile "${state[@]}" -e "$environment" "${selected[@]}" template --skip-deps > "$work/manifests.yaml"
    helmfile "${state[@]}" -e "$environment" -l component=api -l component=gateway --skip-deps \
        write-values --output-file-template "$work/values/{{ .Release.Name }}.yaml" >/dev/null
    helm template contract tests/fixture-entities \
        --set-string "environment=$environment,namespace=$NAMESPACE" \
        --set-file "apiValues=$work/values/hyperfleet-api.yaml" \
        --set-file "gatewayValues=$work/values/hyperfleet-gateway.yaml" \
        --set-file "manifests=$work/manifests.yaml" >/dev/null
    echo "OK: $environment entity definitions, Sentinels and gateway service accounts"
done

# Exercise the matching rule with an unknown fixture plural, an existing
# adapter-less production kind, multiple matches and an unrelated adapter.
cat > "$work/probe.yaml" <<'PROBE'
fixtureEntities:
  - kind: AdapterProbe
    plural: adapterprobes
adapters:
  - name: probe-first
    resourceType: adapterprobes
  - name: unrelated
    resourceType: unrelated
  - name: channel-probe
    resourceType: channels
  - name: probe-second
    resourceType: adapterprobes
PROBE
helmfile "${state[@]}" -e e2e-kind --state-values-file "$work/probe.yaml" \
    -l component=api --skip-deps write-values \
    --output-file-template "$work/probe-values/{{ .Release.Name }}.yaml" >/dev/null
helm template contract tests/fixture-entities --set-string environment=e2e-kind --set probe=true \
    --set-file "apiValues=$work/probe-values/hyperfleet-api.yaml" >/dev/null
echo "OK: required adapters match arbitrary plurals in declared order"

for environment in kind gcp; do
    if helmfile "${state[@]}" -e "$environment" \
        --state-values-file "$PWD/helmfile/environments/e2e/fixture-entities.yaml" build > "$work/rejected.log" 2>&1; then
        echo "ERROR: $environment accepted fixtureEntities" >&2
        exit 1
    fi
    grep -q 'fixtureEntities are only allowed in e2e-kind and e2e-gcp' "$work/rejected.log" || {
        cat "$work/rejected.log" >&2
        exit 1
    }
done
echo "OK: non-E2E environments reject fixtureEntities overrides"
