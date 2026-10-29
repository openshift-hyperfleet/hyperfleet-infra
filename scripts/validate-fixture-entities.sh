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

# Every directory that declares an adapter-config.yaml must declare an
# adapter.name equal to that directory, which is also its release name.
# hyperfleet-infra renders required_adapters from the adapter release names and
# the API matches adapter reports by the declared name, so a mismatch leaves the
# resource permanently unreconciled without failing any deployment step.
# Directories without an adapter-config.yaml only hold shared files (the success
# role's task config) and carry no identity, so they are not checked here.
shopt -s nullglob

check_adapter_identity() {
    local root="$1" config adapter_dir declared
    local configs=("$root"/*/adapter-config.yaml)
    if (( ${#configs[@]} == 0 )); then
        echo "ERROR: no adapter-config.yaml found under $root" >&2
        return 1
    fi
    for config in "${configs[@]}"; do
        adapter_dir=$(basename "$(dirname "$config")")
        declared=$(awk '/^adapter:/{found=1; next} found && /^  name:/{print $2; exit}' "$config")
        if [[ "$declared" != "$adapter_dir" ]]; then
            echo "ERROR: $config declares adapter.name '$declared', expected '$adapter_dir'" >&2
            return 1
        fi
    done
}

# The fixture success role is one task config for both adapter-backed fixture
# plurals, so its resource URL must come from the event rather than a plural.
check_success_role() {
    local config="$1" hard_coded_urls
    grep -q 'source: "event.href"' "$config" || {
        echo "ERROR: $config does not take the resource URL from event.href" >&2
        return 1
    }
    grep -q 'url: "{{ .href }}"' "$config" || {
        echo "ERROR: $config does not read the resource from .href" >&2
        return 1
    }
    grep -q 'url: "{{ .href }}/statuses"' "$config" || {
        echo "ERROR: $config does not report status to .href/statuses" >&2
        return 1
    }
    # Every API URL must be built from the event href. Listing plurals by hand
    # goes stale as soon as another adapter-backed kind appears, so require the
    # prefix instead: a url that does not start from .href is a hard-coded path.
    hard_coded_urls=$(grep -E '^[[:space:]]+url:[[:space:]]' "$config" \
        | grep -vE '^[[:space:]]+url:[[:space:]]*"\{\{ \.href \}\}' || true)
    if [[ -n "$hard_coded_urls" ]]; then
        echo "ERROR: $config builds a URL without .href:" >&2
        echo "$hard_coded_urls" >&2
        return 1
    fi
}

adapters_dir=helmfile/configs/e2e/adapters
success_task_config=$adapters_dir/adapter-success/adapter-task-config.yaml
check_adapter_identity "$adapters_dir"
check_success_role "$success_task_config"
echo "OK: every e2e adapter declares the release name as its identity"
echo "OK: the fixture success role binds the resource URL from the event"

# A guard that only ever sees valid input proves nothing, so break a throwaway
# copy of each input and require the guard to reject it. The non-E2E rejection at
# the end of this script is automated for the same reason.
broken="$work/broken"
mkdir -p "$broken/adapters/parents-success"
cp "$adapters_dir/parents-success/adapter-config.yaml" "$broken/adapters/parents-success/"
sed 's/^  name: parents-success$/  name: not-the-release-name/' \
    "$broken/adapters/parents-success/adapter-config.yaml" > "$broken/mismatch.yaml"
mv "$broken/mismatch.yaml" "$broken/adapters/parents-success/adapter-config.yaml"
if check_adapter_identity "$broken/adapters" 2>/dev/null; then
    echo "ERROR: the adapter identity guard accepted a mismatched adapter.name" >&2
    exit 1
fi

sed 's/^    source: "event.href"$/    source: "event.id"/' \
    "$success_task_config" > "$broken/no-href.yaml"
if check_success_role "$broken/no-href.yaml" 2>/dev/null; then
    echo "ERROR: the success role guard accepted a config without event.href" >&2
    exit 1
fi

# Satisfies every required-shape assertion but adds a second, plural-specific URL,
# which only the URL-origin rule can catch.
cat > "$broken/hard-coded.yaml" <<'HARDCODED'
params:
  - name: "href"
    source: "event.href"
  - name: "resourceStatus"
    source:
      api_call:
        url: "{{ .href }}"
  - name: "childList"
    source:
      api_call:
        url: "/parents/{{ .resourceId }}/cascadechildren"
post:
  post_actions:
    - name: "reportResourceStatus"
      api_call:
        url: "{{ .href }}/statuses"
HARDCODED
if check_success_role "$broken/hard-coded.yaml" 2>/dev/null; then
    echo "ERROR: the success role guard accepted a plural-specific URL" >&2
    exit 1
fi
echo "OK: the adapter identity and URL guards reject broken input"

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
