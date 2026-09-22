#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${HFREVIEW_TEST_IN_CONTAINER:-}" != true ]]; then
  test_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  app_dir=$(dirname -- "$test_script_dir")
  podman run --rm \
    --security-opt label=disable \
    --user 50000:0 \
    --tmpfs /sandbox:rw,mode=1777 \
    --tmpfs /tmp:rw,mode=1777 \
    --tmpfs /mock-state:rw,mode=1777 \
    --tmpfs /mock-bin:rw,mode=1777 \
    --env HFREVIEW_TEST_IN_CONTAINER=true \
    --entrypoint /usr/sbin/bash \
    --volume "$app_dir:/opt/chart:ro" \
    registry.access.redhat.com/hi/git@sha256:ec726bb5db20e24d5c642eb866bba5c89d504b435a6d0a85cc85535cfb365ff5 \
    /opt/chart/tests/run-status.sh
  exit
fi

export MOCK_STATE_DIR=/mock-state
mkdir -p /mock-bin
ln -s /opt/chart/tests/mock-review-tools /mock-bin/gh
ln -s /opt/chart/tests/mock-review-tools /mock-bin/git
ln -s /opt/chart/tests/mock-review-tools /mock-bin/claude
# The review needs these tools in the sandbox image. Mock each one that the
# test image does not contain.
for tool in jq openssl base64; do
  if ! command -v "$tool" >/dev/null; then
    ln -s /opt/chart/tests/mock-review-tools "/mock-bin/$tool"
  fi
done
export PATH="/mock-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export REPOSITORY=openshift-hyperfleet/hyperfleet-api
export PR_NUMBER=210
export EXPECTED_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export SKIP_DRAFT_PRS=true
export TRUSTED_BRANCH=main
export PLUGINS_REPOSITORY=openshift-hyperfleet/hyperfleet-claude-plugins
export PLUGINS_REF=main
export JIRA_ENABLED=false
export CLAUDE_MODEL=claude-opus-4-8
export CLAUDE_MAX_ATTEMPTS=3
export CLAUDE_RETRY_DELAY_SECONDS=0
export MAX_REVIEWS_PER_RUN=25

readonly in_progress_image='Status: **In progress**'
readonly neutral_image='Verdict: **COMMENT**'
readonly approve_image='Verdict: **APPROVE**'
readonly changes_image='Verdict: **REQUEST_CHANGES**'

# The port has no status images. The status text carries the same state.
assert_only_status_image() {
  local expected_text=$1
  local file=$2

  grep --fixed-strings --quiet -- "$expected_text" "$file"
  assert_no_image "$file"
}

assert_no_image() {
  if grep --fixed-strings --quiet -- '![' "$1"; then
    printf 'The status comment contains an unexpected image.\n' >&2
    return 1
  fi
}

assert_no_status_image() {
  local file=$1

  assert_no_image "$file"
  if grep --fixed-strings --quiet -- 'Verdict: **' "$file"; then
    printf 'The status comment contains an unexpected verdict.\n' >&2
    return 1
  fi
}

assert_timestamped_log() {
  local file=$1

  if grep --extended-regexp --invert-match --quiet -- \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' \
    "$file"; then
    printf 'A review log line does not have a UTC timestamp.\n' >&2
    return 1
  fi
}

assert_labels() {
  local expected=$1
  local actual

  actual=$(sort "$MOCK_STATE_DIR/labels")
  if [[ "$actual" != "$expected" ]]; then
    printf 'Unexpected labels: %s\n' "$actual" >&2
    return 1
  fi
}

# Direct Vertex mode: the provider token becomes the Claude Code bearer.
# The mock claude command rejects the run when the environment is wrong.
printf '%s\n' bug >"$MOCK_STATE_DIR/labels"
if ! VERTEX_PROJECT_ID=example-project VERTEX_REGION=global \
  VERTEX_AI_TOKEN=openshell:resolve:env:VERTEX_AI_TOKEN \
  /usr/sbin/bash /opt/chart/files/review.sh >"$MOCK_STATE_DIR/review-vertex.log" 2>&1; then
  cat "$MOCK_STATE_DIR/review-vertex.log" >&2
  exit 1
fi
test -f "$MOCK_STATE_DIR/review-posted"
# Start the remaining scenarios from a clean state.
rm -rf /sandbox/trusted /sandbox/pr /sandbox/plugins "${MOCK_STATE_DIR:?}"/*
printf '%s\n' hf-review/changes-requested hf-review/self-review bug >"$MOCK_STATE_DIR/labels"
review_log_file="$MOCK_STATE_DIR/review.log"
if ! /usr/sbin/bash /opt/chart/files/review.sh >"$review_log_file" 2>&1; then
  cat "$review_log_file" >&2
  exit 1
fi
cat "$review_log_file"
assert_timestamped_log "$review_log_file"
assert_labels $'bug\nhf-review/approved\nhf-review/self-review'

test -f "$MOCK_STATE_DIR/progress-published"
test -f "$MOCK_STATE_DIR/status-final"
assert_only_status_image "$in_progress_image" "$MOCK_STATE_DIR/progress-body"
assert_only_status_image "$approve_image" "$MOCK_STATE_DIR/status-body"
grep --fixed-strings --quiet -- 'Status: **Complete**' \
  "$MOCK_STATE_DIR/status-body"
grep --fixed-strings --quiet -- \
  "https://github.com/$REPOSITORY/pull/$PR_NUMBER#pullrequestreview-77" \
  "$MOCK_STATE_DIR/status-body"
if grep --fixed-strings --quiet -- '## Verdict' \
  "$MOCK_STATE_DIR/status-body" ||
  grep --fixed-strings --quiet -- '## Cross-PR coordination' \
  "$MOCK_STATE_DIR/status-body"; then
  printf 'The status comment duplicates the submitted review.\n' >&2
  exit 1
fi
grep --fixed-strings --quiet -- \
  "<!-- hfreview:v1 repo=$REPOSITORY pr=$PR_NUMBER head=$EXPECTED_HEAD_SHA -->" \
  "$MOCK_STATE_DIR/status-body"

/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery-complete"
test ! -s "$MOCK_STATE_DIR/discovery-complete"

printf '%s\n\n## HyperFleet review\n\nStatus: **In progress**\n' \
  "<!-- hfreview-status:v1 repo=$REPOSITORY pr=$PR_NUMBER head=$EXPECTED_HEAD_SHA -->" \
  >"$MOCK_STATE_DIR/status-body"
rm "$MOCK_STATE_DIR/status-final"

/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery-repair"
grep --fixed-strings --quiet -- \
  "$PR_NUMBER"$'\t'"$EXPECTED_HEAD_SHA" \
  "$MOCK_STATE_DIR/discovery-repair"

/usr/sbin/bash /opt/chart/files/review.sh
test -f "$MOCK_STATE_DIR/status-final"
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1
assert_only_status_image "$approve_image" "$MOCK_STATE_DIR/status-body"

/usr/sbin/bash /opt/chart/files/review.sh
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1

export MOCK_STATE_DIR=/mock-state/model-retry
export MOCK_CLAUDE_MODEL_FAILURES=2
export PR_NUMBER=212
export EXPECTED_HEAD_SHA=cccccccccccccccccccccccccccccccccccccccc
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 3
test "$(wc -l <"$MOCK_STATE_DIR/history-loads")" -eq 4
test -f "$MOCK_STATE_DIR/status-final"
unset MOCK_CLAUDE_MODEL_FAILURES

export MOCK_STATE_DIR=/mock-state/request-changes
export MOCK_REVIEW_VERDICT=REQUEST_CHANGES
export PR_NUMBER=218
export EXPECTED_HEAD_SHA=3333333333333333333333333333333333333333
mkdir -p "$MOCK_STATE_DIR"
printf '%s\n' hf-review/approved bug >"$MOCK_STATE_DIR/labels"
/usr/sbin/bash /opt/chart/files/review.sh
assert_only_status_image "$in_progress_image" "$MOCK_STATE_DIR/progress-body"
assert_only_status_image "$changes_image" "$MOCK_STATE_DIR/status-body"
assert_labels $'bug\nhf-review/changes-requested'
unset MOCK_REVIEW_VERDICT

export MOCK_STATE_DIR=/mock-state/comment
export MOCK_REVIEW_VERDICT=COMMENT
export PR_NUMBER=219
export EXPECTED_HEAD_SHA=4444444444444444444444444444444444444444
mkdir -p "$MOCK_STATE_DIR"
printf '%s\n' hf-review/approved hf-review/changes-requested bug >"$MOCK_STATE_DIR/labels"
/usr/sbin/bash /opt/chart/files/review.sh
assert_labels bug
assert_only_status_image "$neutral_image" "$MOCK_STATE_DIR/status-body"
unset MOCK_REVIEW_VERDICT

export MOCK_STATE_DIR=/mock-state/old-approve
export MOCK_REVIEW_VERDICT=APPROVE
export MOCK_OMIT_VERDICT_MARKER=true
export PR_NUMBER=220
export EXPECTED_HEAD_SHA=5555555555555555555555555555555555555555
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
assert_only_status_image "$approve_image" "$MOCK_STATE_DIR/status-body"
unset MOCK_REVIEW_VERDICT MOCK_OMIT_VERDICT_MARKER

export MOCK_STATE_DIR=/mock-state/draft-to-ready
export MOCK_PR_DRAFT=true
export PR_NUMBER=213
export EXPECTED_HEAD_SHA=dddddddddddddddddddddddddddddddddddddddd
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery-draft"
test ! -s "$MOCK_STATE_DIR/discovery-draft"
export MOCK_PR_DRAFT=false
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery-ready"
grep --fixed-strings --quiet -- \
  "$PR_NUMBER"$'\t'"$EXPECTED_HEAD_SHA" \
  "$MOCK_STATE_DIR/discovery-ready"
/usr/sbin/bash /opt/chart/files/review.sh
test -f "$MOCK_STATE_DIR/status-final"
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1
unset MOCK_PR_DRAFT

export MOCK_STATE_DIR=/mock-state/initial-draft
export MOCK_PR_DRAFT=true
export PR_NUMBER=214
export EXPECTED_HEAD_SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
test ! -e "$MOCK_STATE_DIR/progress-published"
test ! -e "$MOCK_STATE_DIR/claude-calls"
unset MOCK_PR_DRAFT

export MOCK_STATE_DIR=/mock-state/draft-before-start
export MOCK_DRAFT_ON_PULL_READ=2
export PR_NUMBER=215
export EXPECTED_HEAD_SHA=ffffffffffffffffffffffffffffffffffffffff
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
test "$(<"$MOCK_STATE_DIR/pull-read-count")" -eq 2
test ! -e "$MOCK_STATE_DIR/progress-published"
test ! -e "$MOCK_STATE_DIR/claude-calls"
unset MOCK_DRAFT_ON_PULL_READ

export MOCK_STATE_DIR=/mock-state/draft-during-review
export MOCK_DRAFT_DURING_REVIEW=true
export PR_NUMBER=216
export EXPECTED_HEAD_SHA=1111111111111111111111111111111111111111
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1
test ! -e "$MOCK_STATE_DIR/review-posted"
grep --fixed-strings --quiet -- 'Status: **Stopped**' \
  "$MOCK_STATE_DIR/status-body"
grep --fixed-strings --quiet -- 'became a draft during the review' \
  "$MOCK_STATE_DIR/status-body"
assert_no_status_image "$MOCK_STATE_DIR/status-body"
unset MOCK_DRAFT_DURING_REVIEW

export MOCK_STATE_DIR=/mock-state/draft-filter-disabled
export MOCK_PR_DRAFT=true
export SKIP_DRAFT_PRS=false
export PR_NUMBER=217
export EXPECTED_HEAD_SHA=2222222222222222222222222222222222222222
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
grep --fixed-strings --quiet -- \
  "$PR_NUMBER"$'\t'"$EXPECTED_HEAD_SHA" \
  "$MOCK_STATE_DIR/discovery"
/usr/sbin/bash /opt/chart/files/review.sh
test -f "$MOCK_STATE_DIR/status-final"
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1
unset MOCK_PR_DRAFT
export SKIP_DRAFT_PRS=true

export MOCK_STATE_DIR=/mock-state/failure
export MOCK_CLAUDE_FAIL=true
export PR_NUMBER=211
export EXPECTED_HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$MOCK_STATE_DIR"
failed_review_log_file="$MOCK_STATE_DIR/review.log"
set +e
/usr/sbin/bash /opt/chart/files/review.sh >"$failed_review_log_file" 2>&1
failed_review_status=$?
set -e
cat "$failed_review_log_file"
assert_timestamped_log "$failed_review_log_file"
if (( failed_review_status == 0 )); then
  printf 'The failed Claude test returned success.\n' >&2
  exit 1
fi
grep --fixed-strings --quiet -- 'Status: **Failed**' \
  "$MOCK_STATE_DIR/status-body"
assert_no_status_image "$MOCK_STATE_DIR/status-body"
test ! -e "$MOCK_STATE_DIR/label-writes"
unset MOCK_CLAUDE_FAIL

# Add labels to a review that was complete before label updates were supported.
export MOCK_STATE_DIR=/mock-state/label-migration
mkdir -p "$MOCK_STATE_DIR"
touch "$MOCK_STATE_DIR/review-posted" "$MOCK_STATE_DIR/status-exists"
printf '%s\n' \
  "<!-- hfreview-status:v1 repo=$REPOSITORY pr=$PR_NUMBER head=$EXPECTED_HEAD_SHA -->" \
  'Status: **Complete**' \
  "<!-- hfreview:v1 repo=$REPOSITORY pr=$PR_NUMBER head=$EXPECTED_HEAD_SHA -->" \
  >"$MOCK_STATE_DIR/status-body"
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
test -s "$MOCK_STATE_DIR/discovery"
/usr/sbin/bash /opt/chart/files/review.sh
assert_labels hf-review/approved
test ! -e "$MOCK_STATE_DIR/claude-calls"
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
test ! -s "$MOCK_STATE_DIR/discovery"
/usr/sbin/bash /opt/chart/files/review.sh
test "$(wc -l <"$MOCK_STATE_DIR/label-writes")" -eq 1

# Retry each failed label operation without another review.
for operation in GET DELETE POST; do
  export MOCK_STATE_DIR="/mock-state/label-failure-$operation"
  export MOCK_LABEL_FAILURE=$operation
  mkdir -p "$MOCK_STATE_DIR"
  printf '%s\n' hf-review/changes-requested bug >"$MOCK_STATE_DIR/labels"
  if /usr/sbin/bash /opt/chart/files/review.sh; then
    printf 'A failed label operation returned success.\n' >&2
    exit 1
  fi
  grep --fixed-strings --quiet -- 'Status: **Failed**' "$MOCK_STATE_DIR/status-body"
  test ! -e "$MOCK_STATE_DIR/status-final"
  /usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
  test -s "$MOCK_STATE_DIR/discovery"
  unset MOCK_LABEL_FAILURE
  /usr/sbin/bash /opt/chart/files/review.sh
  assert_labels $'bug\nhf-review/approved'
  test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1
  test -f "$MOCK_STATE_DIR/status-final"
done

# Missing or conflicting assessments must not retain a verdict label.
for assessment in missing conflicting; do
  export MOCK_STATE_DIR="/mock-state/assessment-$assessment"
  mkdir -p "$MOCK_STATE_DIR"
  printf '%s\n' hf-review/approved hf-review/changes-requested bug >"$MOCK_STATE_DIR/labels"
  printf '%s\n' \
    "<!-- hfreview:v1 repo=$REPOSITORY pr=$PR_NUMBER head=$EXPECTED_HEAD_SHA -->" \
    >"$MOCK_STATE_DIR/review-body"
  if [[ "$assessment" == conflicting ]]; then
    printf '%s\n' '<!-- hfreview-verdict:v1 result=APPROVE -->' \
      '<!-- hfreview-verdict:v1 result=REQUEST_CHANGES -->' >>"$MOCK_STATE_DIR/review-body"
  fi
  /usr/sbin/bash /opt/chart/files/review.sh
  assert_labels bug
done

# Do not apply a result after the pull request changes during the review.
for change in head closed draft; do
  export MOCK_STATE_DIR="/mock-state/changed-$change"
  mkdir -p "$MOCK_STATE_DIR"
  printf '%s\n' bug >"$MOCK_STATE_DIR/labels"
  case "$change" in
    head) export MOCK_HEAD_AFTER_REVIEW=9999999999999999999999999999999999999999 ;;
    closed) export MOCK_STATE_AFTER_REVIEW=closed ;;
    draft) export MOCK_DRAFT_AFTER_REVIEW=true ;;
  esac
  /usr/sbin/bash /opt/chart/files/review.sh
  assert_labels bug
  test ! -e "$MOCK_STATE_DIR/label-writes"
  grep --fixed-strings --quiet -- 'Status: **Stopped**' "$MOCK_STATE_DIR/status-body"
  unset MOCK_HEAD_AFTER_REVIEW MOCK_STATE_AFTER_REVIEW MOCK_DRAFT_AFTER_REVIEW
done

# Reuse the same comment when the head changes. Hide only after submission.
export MOCK_STATE_DIR=/mock-state/persistent-history
export MOCK_OLD_REVIEW=true
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
rm "$MOCK_STATE_DIR/review-posted" "$MOCK_STATE_DIR/status-final"
export EXPECTED_HEAD_SHA=8888888888888888888888888888888888888888
/usr/sbin/bash /opt/chart/files/review.sh
test "$(wc -l <"$MOCK_STATE_DIR/status-creates")" -eq 1
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 2
test "$(wc -l <"$MOCK_STATE_DIR/hide-calls")" -eq 2

# Retry cleanup after a failure without another model run.
export MOCK_STATE_DIR=/mock-state/hide-failure
export MOCK_HIDE_FAILURE=true
mkdir -p "$MOCK_STATE_DIR"
if /usr/sbin/bash /opt/chart/files/review.sh; then
  printf 'A failed cleanup returned success.\n' >&2
  exit 1
fi
test ! -e "$MOCK_STATE_DIR/status-final"
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
test -s "$MOCK_STATE_DIR/discovery"
unset MOCK_HIDE_FAILURE
/usr/sbin/bash /opt/chart/files/review.sh
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 1
test -f "$MOCK_STATE_DIR/status-final"
unset MOCK_OLD_REVIEW

# Membership errors must stop the review before Claude starts.
export MOCK_STATE_DIR=/mock-state/membership-failure
export MOCK_MEMBERSHIP_FAILURE=true
mkdir -p "$MOCK_STATE_DIR"
if /usr/sbin/bash /opt/chart/files/review.sh; then
  printf 'A failed membership check returned success.\n' >&2
  exit 1
fi
test ! -e "$MOCK_STATE_DIR/claude-calls"
test ! -e "$MOCK_STATE_DIR/hide-calls"
unset MOCK_MEMBERSHIP_FAILURE

# New and edited allowed follow-ups select the same commit again.
export MOCK_STATE_DIR=/mock-state/followup-trigger
mkdir -p "$MOCK_STATE_DIR"
/usr/sbin/bash /opt/chart/files/review.sh
/usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
test ! -s "$MOCK_STATE_DIR/discovery"
for version in new edited; do
  export MOCK_FOLLOWUP_VERSION=$version
  /usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
  test -s "$MOCK_STATE_DIR/discovery"
  /usr/sbin/bash /opt/chart/files/review.sh
  /usr/sbin/bash /opt/chart/files/discover.sh >"$MOCK_STATE_DIR/discovery"
  test ! -s "$MOCK_STATE_DIR/discovery"
  /usr/sbin/bash /opt/chart/files/review.sh
done
test "$(wc -l <"$MOCK_STATE_DIR/claude-calls")" -eq 3
test "$(wc -l <"$MOCK_STATE_DIR/status-creates")" -eq 1
unset MOCK_FOLLOWUP_VERSION

printf 'The HyperFleet review status comment test passed.\n'
