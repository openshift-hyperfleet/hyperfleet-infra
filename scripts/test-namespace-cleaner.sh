#!/usr/bin/env bash
# Run the real namespace-cleaner script against stub kubectl and curl, one case at
# a time, and assert the calls it makes. No cluster or GCP access is needed: the
# stubs serve canned responses, record every call and reject any call they do not
# expect, so this test cannot touch the active cluster or a real project.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
cleaner=helm/namespace-cleaner/scripts/namespace-cleaner.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/base"

# Stub kubectl. Files in $FIXTURES select the responses: <resource>.json for
# lists, fail-<resource> to fail a list, fail-delete-<name> to fail a delete.
cat > "$work/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
case "$*" in
    "get clusterroles -l app.kubernetes.io/managed-by=Helm -o json" \
    | "get clusterrolebindings -l app.kubernetes.io/managed-by=Helm -o json" \
    | "get namespaces -o json")
        if [[ -e "$FIXTURES/fail-$2" ]]; then
            echo "Error from server (Forbidden): $2 is forbidden" >&2
            exit 1
        fi
        cat "$FIXTURES/$2.json" ;;
    "get namespaces -l e2e.hyperfleet.io/run-id -o go-template="*)
        cat "$FIXTURES/labelled.txt" ;;
    "delete namespace "*" --wait=false") ;;
    "delete clusterrole "*" --ignore-not-found" | "delete clusterrolebinding "*" --ignore-not-found")
        if [[ -e "$FIXTURES/fail-delete-$3" ]]; then
            echo "Error from server (InternalError): $3" >&2
            exit 1
        fi ;;
    *)
        echo "UNEXPECTED kubectl $*" >> "$CALLS"
        echo "ERROR: unexpected kubectl call: $*" >&2
        exit 1 ;;
esac
KUBECTL

# Stub curl for the metadata server and the Pub/Sub API. Files in $FIXTURES
# select the responses: cluster-name (absent fails the lookup), fail-token,
# <collection>[.<page token>].json for lists,
# fail-<collection>[.<page token>] to fail a list page, delete-<name> holding the
# HTTP status of a delete (200 when absent).
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
method=GET url="" page="" auth="" metadata="" get="" wfmt=""
reject() {
    echo "UNEXPECTED curl $*" >> "$CALLS"
    echo "ERROR: unexpected curl call: $*" >&2
    exit 2
}
args="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift ;;
        -H)
            case "$2" in
                "Authorization: Bearer "*) auth="${2#Authorization: Bearer }" ;;
                "Metadata-Flavor: Google") metadata=1 ;;
                *) reject "$args" ;;
            esac
            shift ;;
        --data-urlencode) page="${2#pageToken=}"; shift ;;
        -w) wfmt="$2"; shift ;;
        -m) shift ;;
        -G) get=1 ;;
        -sS) ;;
        https://* | http://*) url="$1" ;;
        *) reject "$args" ;;
    esac
    shift
done
echo "curl $method $url${page:+ pageToken=$page}" >> "$CALLS"
# The cleaner reads the status code from the last line of the output.
[[ "$wfmt" == '\n%{http_code}' ]] || reject "$args"
[[ -z "$page" || -n "$get" ]] || reject "$args"
respond() { printf '%s\n%s' "$2" "$1"; }

token_url=http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
cluster_name_url=http://metadata.google.internal/computeMetadata/v1/instance/attributes/cluster-name
api=https://pubsub.googleapis.com/v1/projects/test-project
case "$method $url" in
    "GET $cluster_name_url")
        [[ -n "$metadata" ]] || reject "$args"
        if [[ -e "$FIXTURES/cluster-name" ]]; then
            respond 200 "$(cat "$FIXTURES/cluster-name")"
        else
            respond 404 'not found'
        fi ;;
    "GET $token_url")
        [[ -n "$metadata" ]] || reject "$args"
        if [[ -e "$FIXTURES/fail-token" ]]; then
            respond 500 'metadata server unavailable'
        else
            respond 200 '{"access_token":"stub-token","expires_in":3599,"token_type":"Bearer"}'
        fi ;;
    "GET $api/topics" | "GET $api/subscriptions")
        [[ "$auth" == stub-token ]] || reject "$args"
        page_file="${url##*/}${page:+.$page}"
        if [[ -e "$FIXTURES/fail-$page_file" ]]; then
            respond 403 '{"error":{"code":403,"status":"PERMISSION_DENIED","message":"denied"}}'
        else
            respond 200 "$(cat "$FIXTURES/$page_file.json")"
        fi ;;
    "DELETE $api/topics/"* | "DELETE $api/subscriptions/"*)
        [[ "$auth" == stub-token ]] || reject "$args"
        code=200
        if [[ -e "$FIXTURES/delete-${url##*/}" ]]; then code=$(cat "$FIXTURES/delete-${url##*/}"); fi
        case "$code" in
            404) respond 404 '{"error":{"code":404,"status":"NOT_FOUND","message":"Resource not found"}}' ;;
            2??) respond "$code" '{}' ;;
            *) respond "$code" '{"error":{"code":500,"status":"INTERNAL","message":"internal error"}}' ;;
        esac ;;
    *) reject "$args" ;;
esac
CURL
chmod +x "$work/bin/kubectl" "$work/bin/curl"

# Run namespaces: LIVE is Active, TERM is Terminating, GONE and RC_GONE do not
# exist. Run IDs are 19-digit Prow build IDs.
LIVE=e2e-1000000000000000001
TERM=e2e-1000000000000000002
GONE=e2e-1000000000000000003
RC_GONE=rc-e2e-1000000000000000004
API=https://pubsub.googleapis.com/v1/projects/test-project

cat > "$work/base/namespaces.json" <<EOF
{"items":[
  {"metadata":{"name":"default"},"status":{"phase":"Active"}},
  {"metadata":{"name":"kube-system"},"status":{"phase":"Active"}},
  {"metadata":{"name":"hyperfleet-cleaner"},"status":{"phase":"Active"}},
  {"metadata":{"name":"$LIVE"},"status":{"phase":"Active"}},
  {"metadata":{"name":"$TERM"},"status":{"phase":"Terminating"}}
]}
EOF

# Ignored names: a developer namespace (e2e-123), a 20-digit ID, a name that
# contains but does not start with a run namespace, and a personal topic.
cat > "$work/base/subscriptions.json" <<EOF
{"subscriptions":[
  {"name":"projects/test-project/subscriptions/$GONE-clusters-adapter"},
  {"name":"projects/test-project/subscriptions/$LIVE-clusters-adapter"},
  {"name":"projects/test-project/subscriptions/$TERM-nodepools-adapter"},
  {"name":"projects/test-project/subscriptions/e2e-123-clusters-adapter"},
  {"name":"projects/test-project/subscriptions/e2e-10000000000000000030-clusters"},
  {"name":"projects/test-project/subscriptions/hyperfleet-$GONE-clusters"},
  {"name":"projects/test-project/subscriptions/dandreev-clusters"}
],"nextPageToken":"page2"}
EOF
cat > "$work/base/subscriptions.page2.json" <<EOF
{"subscriptions":[
  {"name":"projects/test-project/subscriptions/$RC_GONE-parents-adapter"}
]}
EOF
cat > "$work/base/topics.json" <<EOF
{"topics":[
  {"name":"projects/test-project/topics/$GONE-clusters"},
  {"name":"projects/test-project/topics/$LIVE-clusters"},
  {"name":"projects/test-project/topics/$RC_GONE-cascadechildren"},
  {"name":"projects/test-project/topics/e2e-123-clusters"},
  {"name":"projects/test-project/topics/dandreev-topic"}
]}
EOF

# The stub ignores the label selector, so the list also returns objects without
# the Helm label, which the cleaner must skip on its own check.
cat > "$work/base/clusterrolebindings.json" <<EOF
{"items":[
  {"metadata":{"name":"$GONE-adapter-crb","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"$GONE"}}},
  {"metadata":{"name":"$LIVE-adapter-crb","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"$LIVE"}}},
  {"metadata":{"name":"unlabelled-crb","annotations":{"meta.helm.sh/release-namespace":"$GONE"}}},
  {"metadata":{"name":"system-crb","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"kube-system"}}},
  {"metadata":{"name":"dev-crb","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"e2e-123"}}}
]}
EOF
cat > "$work/base/clusterroles.json" <<EOF
{"items":[
  {"metadata":{"name":"$GONE-adapter-cr","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"$GONE"}}},
  {"metadata":{"name":"$RC_GONE-applier-cr","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"$RC_GONE"}}},
  {"metadata":{"name":"$TERM-adapter-cr","labels":{"app.kubernetes.io/managed-by":"Helm"},
    "annotations":{"meta.helm.sh/release-namespace":"$TERM"}}},
  {"metadata":{"name":"kustomize-cr","labels":{"app.kubernetes.io/managed-by":"Kustomize"},
    "annotations":{"meta.helm.sh/release-namespace":"$GONE"}}},
  {"metadata":{"name":"helm-no-release-cr","labels":{"app.kubernetes.io/managed-by":"Helm"}}}
]}
EOF

# The cluster the cleaner runs on, as the metadata server reports it.
printf '%s' test-cluster > "$work/base/cluster-name"

# One stale labelled namespace, so every case shows whether the namespace rule ran.
echo "old-run-ns|2020-01-01T00:00:00Z|Active" > "$work/base/labelled.txt"

# The deletes of a full run, in order.
pubsub_deletes="curl DELETE $API/subscriptions/$GONE-clusters-adapter
curl DELETE $API/subscriptions/$RC_GONE-parents-adapter
curl DELETE $API/topics/$GONE-clusters
curl DELETE $API/topics/$RC_GONE-cascadechildren"
rbac_deletes="kubectl delete clusterrolebinding $GONE-adapter-crb --ignore-not-found
kubectl delete clusterrole $GONE-adapter-cr --ignore-not-found
kubectl delete clusterrole $RC_GONE-applier-cr --ignore-not-found"
namespace_delete="kubectl delete namespace old-run-ns --wait=false"
expected_deletes="$pubsub_deletes
$rbac_deletes
$namespace_delete"

failures=0
case_name="" calls="" log="" status=0

# new_case <name>: a fixture directory copied from the base fixtures.
new_case() {
    case_name="$1"
    cp -R "$work/base" "$work/$case_name"
}

# run_case [VAR=value...]: run the cleaner for the current case, with orphans
# enabled unless overridden.
run_case() {
    calls="$work/$case_name.calls" log="$work/$case_name.log"
    : > "$calls"
    status=0
    env PATH="$work/bin:$PATH" CALLS="$calls" FIXTURES="$work/$case_name" \
        LABEL_SELECTOR=e2e.hyperfleet.io/run-id DRY_RUN=false \
        ORPHANS_ENABLED=true PUBSUB_PROJECT=test-project OWNER_CLUSTER=test-cluster "$@" \
        bash "$cleaner" > "$log" 2>&1 || status=$?
}

fail() {
    failures=$((failures + 1))
    echo "FAIL ($case_name): $*" >&2
    echo "--- calls ---" >&2; cat "$calls" >&2
    echo "--- log ---" >&2; cat "$log" >&2
}

expect_status() {
    [[ "$status" -eq "$1" ]] || fail "exit status $status, expected $1"
}
expect_call() {
    grep -Fxq -- "$1" "$calls" || fail "missing call: $1"
}
expect_no_call() {
    if grep -Eq -- "$1" "$calls"; then fail "unexpected call matching: $1"; fi
}
expect_log() {
    grep -Fq -- "$1" "$log" || fail "missing log line: $1"
}
expect_deletes() {
    local actual
    actual=$(grep -E '^(curl DELETE|kubectl delete) ' "$calls" || true)
    [[ "$actual" == "$1" ]] || fail "deletes differ, expected:
$1
got:
$actual"
}
# No stub rejected a call, and the access token never reached the log.
expect_clean() {
    expect_no_call '^UNEXPECTED'
    if grep -q stub-token "$log"; then fail "the access token was logged"; fi
}
# A skipped kind: only the given deletes ran, the namespace rule still ran, and
# the run failed.
# usage: expect_skipped <error> <skip log line> <expected deletes>
expect_skipped() {
    expect_status 1
    expect_clean
    expect_deletes "$3"
    expect_log "[ERROR] $1"
    expect_log "[ERROR] $2"
    expect_log "[INFO] Namespace cleaner run complete"
    expect_log "[ERROR] Exiting with an error: an orphan kind was skipped"
}
pubsub_skipped="Pub/Sub orphan cleanup skipped: no Pub/Sub resource was deleted in this run"
rbac_skipped="RBAC orphan cleanup skipped: no ClusterRole or ClusterRoleBinding was deleted in this run"
all_skipped="Orphan cleanup skipped: no orphan was deleted in this run"

new_case full-run
run_case
expect_status 0
expect_clean
expect_deletes "$expected_deletes"
expect_call "curl GET $API/subscriptions pageToken=page2"
expect_log "[INFO] Keeping Pub/Sub subscription '$TERM-nodepools-adapter' (namespace '$TERM' exists)"
expect_log "[INFO] Keeping clusterrolebinding '$LIVE-adapter-crb' (namespace '$LIVE' exists)"
expect_log "[INFO] Deleted Pub/Sub topic '$GONE-clusters' (namespace '$GONE' not found)"
expect_log "[INFO] Orphan cleanup summary: found=12 kept=5 deleted=7 failed=0 dry_run=false"
# Every resource list comes before the namespace list, and the namespace list
# comes before the first delete.
ns_line=$(grep -nFx "kubectl get namespaces -o json" "$calls" | cut -d: -f1 || true)
last_list=$(grep -nE '^(curl GET|kubectl get cluster)' "$calls" | tail -1 | cut -d: -f1 || true)
first_delete=$(grep -nE '^(curl DELETE|kubectl delete) ' "$calls" | head -1 | cut -d: -f1 || true)
if [[ -z "$ns_line" || -z "$last_list" || "$ns_line" -le "$last_list" || "$ns_line" -ge "$first_delete" ]]; then
    fail "the namespace list must come after every resource list and before the first delete"
fi
echo "OK: orphans of deleted run namespaces are deleted; live, Terminating and non-run resources are kept"

new_case delete-results
echo 404 > "$work/$case_name/delete-$GONE-clusters-adapter"
echo 500 > "$work/$case_name/delete-$GONE-clusters"
touch "$work/$case_name/fail-delete-$GONE-adapter-crb"
run_case
expect_status 0
expect_clean
expect_deletes "$expected_deletes"
expect_log "[INFO] Pub/Sub subscription '$GONE-clusters-adapter' was already deleted (namespace '$GONE' not found)"
expect_log "[WARN] Failed to delete Pub/Sub topic '$GONE-clusters' (HTTP 500): INTERNAL internal error"
expect_log "[WARN] Failed to delete clusterrolebinding '$GONE-adapter-crb'"
expect_log "[INFO] Orphan cleanup summary: found=12 kept=5 deleted=5 failed=2 dry_run=false"
echo "OK: a 404 counts as deleted; a failed delete is logged and the rest continue"

new_case dry-run
run_case DRY_RUN=true
expect_status 0
expect_clean
expect_deletes ""
expect_log "[DRY-RUN] Would delete Pub/Sub subscription '$RC_GONE-parents-adapter' (namespace '$RC_GONE' not found)"
expect_log "[DRY-RUN] Would delete clusterrole '$GONE-adapter-cr' (namespace '$GONE' not found)"
expect_log "[DRY-RUN] Would delete namespace 'old-run-ns'"
expect_log "[INFO] Orphan cleanup summary: found=12 kept=5 deleted=0 failed=0 dry_run=true"
echo "OK: DRY_RUN lists the orphans and deletes nothing"

new_case disabled
run_case ORPHANS_ENABLED=false PUBSUB_PROJECT=
expect_status 0
expect_clean
expect_no_call '^curl '
expect_no_call 'cluster(role|rolebinding)s? '
expect_no_call '^kubectl get namespaces -o json$'
expect_deletes "kubectl delete namespace old-run-ns --wait=false"
echo "OK: with orphans disabled the cleaner makes no Pub/Sub or RBAC call"

new_case other-cluster
printf '%s' dev-cluster > "$work/$case_name/cluster-name"
run_case
expect_skipped "This cluster is 'dev-cluster', not the owner cluster 'test-cluster'" "$pubsub_skipped" "$rbac_deletes
$namespace_delete"
expect_no_call '^curl GET https://'

new_case cluster-name-failure
rm "$work/$case_name/cluster-name"
run_case
expect_skipped "Failed to read the cluster name from the metadata server (HTTP 404)" "$pubsub_skipped" "$rbac_deletes
$namespace_delete"
expect_no_call '^curl GET https://'

new_case token-failure
touch "$work/$case_name/fail-token"
run_case
expect_skipped "Failed to get an access token from the metadata server (HTTP 500)" "$pubsub_skipped" "$rbac_deletes
$namespace_delete"

for failed in subscriptions subscriptions.page2 topics; do
    new_case "pubsub-$failed-failure"
    touch "$work/$case_name/fail-$failed"
    run_case
    expect_skipped "Failed to list Pub/Sub ${failed%.page2} in project 'test-project' (HTTP 403): PERMISSION_DENIED denied" \
        "$pubsub_skipped" "$rbac_deletes
$namespace_delete"
done

echo "OK: another cluster, no token or a failed Pub/Sub list skips Pub/Sub only; RBAC and the namespace rule still run, and the run fails"

for failed in clusterrolebindings clusterroles; do
    new_case "kubectl-$failed-failure"
    touch "$work/$case_name/fail-$failed"
    run_case
    expect_skipped "Failed to list $failed" "$rbac_skipped" "$pubsub_deletes
$namespace_delete"
done
echo "OK: a failed RBAC list skips RBAC only; Pub/Sub and the namespace rule still run, and the run fails"

new_case kubectl-namespaces-failure
touch "$work/$case_name/fail-namespaces"
run_case
expect_skipped "Failed to list namespaces" "$all_skipped" "$namespace_delete"

new_case empty-namespaces
echo '{"items":[]}' > "$work/$case_name/namespaces.json"
run_case
expect_skipped "The namespace list is empty" "$all_skipped" "$namespace_delete"
echo "OK: a failed or empty namespace list deletes no orphan, still runs the namespace rule and fails the run"

# Bad settings stop the cleaner before its first call.
for bad in "PUBSUB_PROJECT=Bad_Project" "ORPHANS_ENABLED=maybe" "OWNER_CLUSTER="; do
    new_case "bad-setting-${bad%%=*}"
    run_case "$bad"
    expect_status 1
    if [[ -s "$calls" ]]; then fail "made calls despite $bad"; fi
    expect_log "[ERROR] ${bad%%=*} must"
done
echo "OK: invalid settings stop the cleaner before any call"

if [[ "$failures" -ne 0 ]]; then
    echo "ERROR: $failures namespace-cleaner check(s) failed" >&2
    exit 1
fi
echo "OK: namespace-cleaner orphan rules"
