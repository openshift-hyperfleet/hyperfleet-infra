#!/usr/bin/env bash
# SC2016: the single-quoted scripts expand inside the sandbox, not here.
# SC2034: agent-runtime.sh reads gateway_login_at.
# shellcheck disable=SC2016,SC2034

set -Eeuo pipefail
umask 077

# shellcheck source=/dev/null
source /opt/agent-runtime/agent-runtime.sh

timestamp_log_stream() {
  local line
  local timestamp

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z([[:space:]]|$) ]]; then
      printf '%s\n' "$line"
      continue
    fi
    printf -v timestamp '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    printf '%s %s\n' "$timestamp" "$line"
  done
}

finish_log_stream() {
  local exit_status=${1:-$?}

  trap - EXIT
  exec 1>&3 2>&4
  exec 3>&- 4>&-
  wait "$log_process_pid" || true
  exit "$exit_status"
}

exec 3>&1 4>&2
coproc HFREVIEW_LOG_PROCESS { TZ=UTC timestamp_log_stream >&3; }
log_process_pid=$HFREVIEW_LOG_PROCESS_PID
log_read_fd=${HFREVIEW_LOG_PROCESS[0]}
log_write_fd=${HFREVIEW_LOG_PROCESS[1]}
exec 1>&"$log_write_fd" 2>&1
exec {log_read_fd}<&-
exec {log_write_fd}>&-
trap 'finish_log_stream "$?"' EXIT

required_variables=(
  GATEWAY_NAME
  GATEWAY_ENDPOINT
  OIDC_ISSUER
  OIDC_CLIENT_ID
  OIDC_AUDIENCE
  OPENSHELL_OIDC_CLIENT_SECRET
  OPENSHELL_WORKSPACE
  DISCOVERY_SANDBOX_NAME
  SANDBOX_NAME_PREFIX
  SANDBOX_OWNER
  SANDBOX_SOURCE
  CLAUDE_PROVIDER
  GITHUB_PROVIDER
  REPOSITORY
  SKIP_DRAFT_PRS
  MAX_REVIEWS_PER_RUN
  TRUSTED_BRANCH
  PLUGINS_REPOSITORY
  PLUGINS_REF
  CLAUDE_MODEL
  CLAUDE_MAX_ATTEMPTS
  CLAUDE_RETRY_DELAY_SECONDS
  GATEWAY_LOGIN_REFRESH_SECONDS
  REVIEW_POLL_SECONDS
  SANDBOX_READY_TIMEOUT_SECONDS
  DISCOVERY_TIMEOUT_SECONDS
  REVIEW_TIMEOUT_SECONDS
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf 'Required variable %s is empty.\n' "$variable" >&2
    exit 1
  fi
done

# JIRA validation is optional. When JIRA_PROVIDER is set, the review sandbox
# also attaches that provider and review.sh writes the jira-cli configuration.
jira_provider_args=()
jira_enabled=false
if [[ -n "${JIRA_PROVIDER:-}" ]]; then
  for variable in JIRA_SERVER JIRA_PROJECT; do
    if [[ -z "${!variable:-}" ]]; then
      printf 'JIRA_PROVIDER is set but %s is empty.\n' "$variable" >&2
      exit 1
    fi
  done
  jira_provider_args=(--provider "$JIRA_PROVIDER")
  jira_enabled=true
fi
readonly jira_enabled

# The gateway rejects sandbox names longer than 19 characters: one leading
# character, up to 17 more, one trailing character.
readonly max_sandbox_name_length=19
# hfreview-discovery is a single fixed name reused every run. If a prior run's
# sandbox is not fully gone by the next scheduled run -- whether because its
# own cleanup is still in flight (terminationGracePeriodSeconds) or because
# cleanup silently failed and leaked the sandbox -- create fails with
# "already exists" while list/delete can no longer find it, permanently
# wedging every later run on the same fixed name. Appending a suffix unique
# to this pod means a leftover sandbox under the old name can never block
# a new run.
readonly discovery_sandbox_suffix_length=3

if [[ ! "$MAX_REVIEWS_PER_RUN" =~ ^[1-9][0-9]*$ ]]; then
  printf 'MAX_REVIEWS_PER_RUN is not valid.\n' >&2
  exit 1
fi

if [[ "$SKIP_DRAFT_PRS" != true && "$SKIP_DRAFT_PRS" != false ]]; then
  printf 'SKIP_DRAFT_PRS must be true or false.\n' >&2
  exit 1
fi

if [[ ! "$CLAUDE_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
  [[ ! "$CLAUDE_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'The Claude retry configuration is not valid.\n' >&2
  exit 1
fi

if [[ ! "$GATEWAY_LOGIN_REFRESH_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  [[ ! "$REVIEW_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'The gateway login or review poll interval is not valid.\n' >&2
  exit 1
fi

if ! is_valid_sandbox_name "$DISCOVERY_SANDBOX_NAME" ||
  ! is_valid_sandbox_name "$SANDBOX_NAME_PREFIX"; then
  printf 'A sandbox name is not valid.\n' >&2
  exit 1
fi

if (( ${#DISCOVERY_SANDBOX_NAME} + 1 + discovery_sandbox_suffix_length >
  max_sandbox_name_length )); then
  printf 'DISCOVERY_SANDBOX_NAME leaves no room for a %s-character unique suffix (max %s characters total).\n' \
    "$discovery_sandbox_suffix_length" "$max_sandbox_name_length" >&2
  exit 1
fi

export OPENSHELL_GATEWAY="$GATEWAY_NAME"
export OPENSHELL_NO_BROWSER=1
export OPENSHELL_WORKSPACE

if [[ "${OPENSHELL_GATEWAY_INSECURE:-}" == true ]]; then
  export RUST_LOG=warn,openshell_cli::tls=error
fi

readonly pending_pulls_file=/work/pending-pulls.tsv
readonly sandbox_ready_file=/tmp/hfreview-upload-ready
readonly sandbox_upload_dir=/work/hfreview-upload-files
readonly discovery_upload_file=$sandbox_upload_dir/discover.sh
readonly review_upload_file=$sandbox_upload_dir/review.sh
readonly history_upload_file=$sandbox_upload_dir/history.sh
active_pids=()
gateway_login_at=0

mkdir -p "$sandbox_upload_dir"
cp --dereference /opt/hfreview/discover.sh "$discovery_upload_file"
cp --dereference /opt/hfreview/review.sh "$review_upload_file"
cp --dereference /opt/hfreview/history.sh "$history_upload_file"
chmod 0400 "$discovery_upload_file" "$review_upload_file" "$history_upload_file"

if [[ ! -f "$discovery_upload_file" || -L "$discovery_upload_file" ||
  ! -f "$review_upload_file" || -L "$review_upload_file" ||
  ! -f "$history_upload_file" || -L "$history_upload_file" ]]; then
  printf 'Cannot stage regular runner files for upload.\n' >&2
  exit 1
fi

terminate_children() {
  local exit_status=$1
  local child_pid

  trap - INT TERM
  for child_pid in "${active_pids[@]}"; do
    if [[ -n "$child_pid" ]]; then
      kill "$child_pid" 2>/dev/null || true
    fi
  done
  for child_pid in "${active_pids[@]}"; do
    if [[ -n "$child_pid" ]]; then
      wait "$child_pid" 2>/dev/null || true
    fi
  done
  exit "$exit_status"
}

trap 'terminate_children 130' INT
trap 'terminate_children 143' TERM

cleanup_current_sandbox() {
  local command_status=$?
  local cleanup_status=0

  trap - EXIT INT TERM

  if [[ "$delete_on_exit" == true ]]; then
    printf 'Delete sandbox %s.\n' "$current_sandbox_name"
    if renew_gateway_login "$config_root"; then
      openshell_for "$config_root" sandbox delete "$current_sandbox_name" ||
        cleanup_status=$?
    else
      cleanup_status=$?
    fi
  fi

  if [[ -n "$exec_pid" ]]; then
    kill "$exec_pid" 2>/dev/null || true
    wait "$exec_pid" 2>/dev/null || true
  fi

  if [[ -n "$create_pid" ]]; then
    kill "$create_pid" 2>/dev/null || true
    wait "$create_pid" 2>/dev/null || true
  fi

  if (( command_status == 0 && cleanup_status != 0 )); then
    command_status=$cleanup_status
  fi

  exit "$command_status"
}

# The CLI of this gateway build does not accept --upload together with a
# command on sandbox create. Upload the scripts after the sandbox is ready.
upload_to_current_sandbox() {
  local local_path=$1
  local sandbox_path=$2

  renew_gateway_login "$config_root"
  openshell_for "$config_root" sandbox upload \
    "$current_sandbox_name" "$local_path" "$sandbox_path"
}

wait_for_current_sandbox() {
  local ready_deadline=$((SECONDS + SANDBOX_READY_TIMEOUT_SECONDS))
  local create_status

  until renew_gateway_login "$config_root" &&
    openshell_for "$config_root" sandbox exec \
    --name "$current_sandbox_name" \
    --timeout 10 \
    --no-tty \
    /usr/bin/bash -c '[[ -r "$1" ]]' bash "$sandbox_ready_file" \
    >/dev/null 2>&1; do
    if ! kill -0 "$create_pid" 2>/dev/null; then
      set +e
      wait "$create_pid"
      create_status=$?
      set -e
      create_pid=""
      if [[ -r "$create_log" ]]; then
        cat "$create_log" >&2
      fi
      if (( create_status == 0 )); then
        create_status=1
      fi
      return "$create_status"
    fi

    if (( SECONDS >= ready_deadline )); then
      if [[ -r "$create_log" ]]; then
        cat "$create_log" >&2
      fi
      printf 'Sandbox %s was not ready after %s seconds.\n' \
        "$current_sandbox_name" "$SANDBOX_READY_TIMEOUT_SECONDS" >&2
      return 1
    fi

    sleep 2
  done
}

run_discovery() (
  set -Eeuo pipefail

  config_root=/work/discovery-config
  current_sandbox_name="$DISCOVERY_SANDBOX_NAME-${HOSTNAME: -discovery_sandbox_suffix_length}"
  if ! is_valid_sandbox_name "$current_sandbox_name"; then
    printf 'Discovery sandbox name %s is not valid.\n' "$current_sandbox_name" >&2
    return 1
  fi
  create_log="/tmp/openshell-create-$current_sandbox_name.log"
  create_pid=""
  exec_pid=""
  delete_on_exit=false
  gateway_login_at=0

  trap cleanup_current_sandbox EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  configure_gateway "$config_root"
  printf 'Create discovery sandbox %s.\n' "$current_sandbox_name"
  delete_on_exit=true
  env \
    HOME="$config_root/home" \
    XDG_CONFIG_HOME="$config_root/config" \
    XDG_STATE_HOME="$config_root/state" \
    openshell sandbox create \
    --name "$current_sandbox_name" \
    --from "$SANDBOX_SOURCE" \
    --keep \
    --provider "$GITHUB_PROVIDER" \
    --policy /etc/hfreview/discovery-policy.yaml \
    --label "managed-by=$SANDBOX_OWNER" \
    --label workload=discovery \
    --no-auto-providers \
    --no-tty \
    -- /usr/bin/bash -c \
    'printf "%s\n" ready >"$1"; exec /usr/bin/tail --follow /dev/null' \
    bash "$sandbox_ready_file" \
    >"$create_log" 2>&1 &
  create_pid=$!

  wait_for_current_sandbox
  upload_to_current_sandbox "$discovery_upload_file" /tmp/hfreview-discover.sh
  upload_to_current_sandbox "$history_upload_file" /tmp/history.sh
  printf 'Find pull request heads that need an HyperFleet review.\n'
  renew_gateway_login "$config_root" true
  env \
    HOME="$config_root/home" \
    XDG_CONFIG_HOME="$config_root/config" \
    XDG_STATE_HOME="$config_root/state" \
    openshell sandbox exec \
    --name "$current_sandbox_name" \
    --timeout "$DISCOVERY_TIMEOUT_SECONDS" \
    --no-tty \
    --env "REPOSITORY=$REPOSITORY" \
    --env "SKIP_DRAFT_PRS=$SKIP_DRAFT_PRS" \
    --env "MAX_REVIEWS_PER_RUN=$MAX_REVIEWS_PER_RUN" \
    --env "COMMENT_ORG_MEMBERS=${COMMENT_ORG_MEMBERS:-true}" \
    --env "COMMENT_ALLOWED_AUTHORS=${COMMENT_ALLOWED_AUTHORS:-}" \
    --env CI=true \
    /usr/bin/bash /tmp/hfreview-discover.sh \
    >"$pending_pulls_file" &
  exec_pid=$!
  set +e
  wait "$exec_pid"
  exec_status=$?
  set -e
  exec_pid=""
  if (( exec_status != 0 )); then
    return "$exec_status"
  fi
)

run_review() (
  set -Eeuo pipefail

  local pr_number=$1
  local head_sha=$2
  local short_head=${head_sha:0:8}
  local review_log_file="/tmp/hfreview-run-$pr_number-$short_head.log"
  local review_status_file="/tmp/hfreview-run-$pr_number-$short_head.status"
  local review_status_tmp_file="$review_status_file.tmp"
  local detached_review_command

  config_root="/work/review-config-$pr_number-$short_head"
  current_sandbox_name="$SANDBOX_NAME_PREFIX-$pr_number-$short_head"
  if ! is_valid_sandbox_name "$current_sandbox_name"; then
    printf 'Sandbox name %s is not valid.\n' "$current_sandbox_name" >&2
    return 1
  fi
  create_log="/tmp/openshell-create-$current_sandbox_name.log"
  create_pid=""
  exec_pid=""
  delete_on_exit=false
  gateway_login_at=0

  trap cleanup_current_sandbox EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  configure_gateway "$config_root"
  printf 'Create sandbox %s for %s#%s.\n' \
    "$current_sandbox_name" "$REPOSITORY" "$pr_number"
  delete_on_exit=true
  env \
    HOME="$config_root/home" \
    XDG_CONFIG_HOME="$config_root/config" \
    XDG_STATE_HOME="$config_root/state" \
    openshell sandbox create \
    --name "$current_sandbox_name" \
    --from "$SANDBOX_SOURCE" \
    --keep \
    --provider "$CLAUDE_PROVIDER" \
    --provider "$GITHUB_PROVIDER" \
    "${jira_provider_args[@]}" \
    --policy /etc/hfreview/policy.yaml \
    --label "managed-by=$SANDBOX_OWNER" \
    --label workload=review \
    --label "review-pr=$pr_number" \
    --label "review-head=$short_head" \
    --no-auto-providers \
    --no-tty \
    -- /usr/bin/bash -c \
    'printf "%s\n" ready >"$1"; exec /usr/bin/tail --follow /dev/null' \
    bash "$sandbox_ready_file" \
    >"$create_log" 2>&1 &
  create_pid=$!

  wait_for_current_sandbox
  upload_to_current_sandbox "$review_upload_file" /tmp/hfreview.sh
  upload_to_current_sandbox "$history_upload_file" /tmp/history.sh
  printf 'Run the HyperFleet review for %s#%s at %s.\n' \
    "$REPOSITORY" "$pr_number" "$head_sha"

  read -r -d '' detached_review_command <<'EOF' || true
umask 077
trap '' HUP
exec </dev/null >/dev/null 2>&1
set +e
/usr/bin/bash /tmp/hfreview.sh >"$1" 2>&1
review_status=$?
printf '%s\n' "$review_status" >"$2"
/usr/bin/mv "$2" "$3"
EOF

  renew_gateway_login "$config_root" true
  openshell_for "$config_root" sandbox exec \
    --name "$current_sandbox_name" \
    --timeout 30 \
    --no-tty \
    --env "REPOSITORY=$REPOSITORY" \
    --env "PR_NUMBER=$pr_number" \
    --env "EXPECTED_HEAD_SHA=$head_sha" \
    --env "SKIP_DRAFT_PRS=$SKIP_DRAFT_PRS" \
    --env "TRUSTED_BRANCH=$TRUSTED_BRANCH" \
    --env "PLUGINS_REPOSITORY=$PLUGINS_REPOSITORY" \
    --env "PLUGINS_REF=$PLUGINS_REF" \
    --env "JIRA_ENABLED=$jira_enabled" \
    --env "JIRA_SERVER=${JIRA_SERVER:-}" \
    --env "JIRA_PROJECT=${JIRA_PROJECT:-}" \
    --env "VERTEX_PROJECT_ID=${VERTEX_PROJECT_ID:-}" \
    --env "VERTEX_REGION=${VERTEX_REGION:-}" \
    --env "COMMENT_ORG_MEMBERS=${COMMENT_ORG_MEMBERS:-true}" \
    --env "COMMENT_ALLOWED_AUTHORS=${COMMENT_ALLOWED_AUTHORS:-}" \
    --env "CLAUDE_MODEL=$CLAUDE_MODEL" \
    --env "CLAUDE_MAX_ATTEMPTS=$CLAUDE_MAX_ATTEMPTS" \
    --env "CLAUDE_RETRY_DELAY_SECONDS=$CLAUDE_RETRY_DELAY_SECONDS" \
    /usr/bin/setsid --fork /usr/bin/bash -c "$detached_review_command" \
    bash "$review_log_file" "$review_status_tmp_file" "$review_status_file"

  set +e
  wait_for_detached_work "$config_root" "$current_sandbox_name" \
    "$review_log_file" "$review_status_file" \
    "$REVIEW_TIMEOUT_SECONDS" "$REVIEW_POLL_SECONDS"
  exec_status=$?
  set -e
  if (( exec_status != 0 )); then
    return "$exec_status"
  fi

  printf 'The HyperFleet review for %s#%s is complete.\n' \
    "$REPOSITORY" "$pr_number"
)

control_config_root=/work/control-config
configure_gateway "$control_config_root"
openshell_for "$control_config_root" whoami

for provider_name in "$GITHUB_PROVIDER" "$CLAUDE_PROVIDER"; do
  if ! openshell_for "$control_config_root" provider get "$provider_name" \
    >/dev/null; then
    printf 'Required provider %s is not available in workspace %s.\n' \
      "$provider_name" "$OPENSHELL_WORKSPACE" >&2
    exit 1
  fi
done

# Several releases can share one workspace. The owner label keeps each
# release from deleting the in-flight sandboxes of another release.
cleanup_stale_sandboxes "$control_config_root" "managed-by=$SANDBOX_OWNER"

run_discovery &
discovery_pid=$!
active_pids=("$discovery_pid")
if ! wait "$discovery_pid"; then
  active_pids=()
  printf 'Pull request discovery failed.\n' >&2
  exit 1
fi
active_pids=()

mapfile -t pending_pulls <"$pending_pulls_file"
if (( ${#pending_pulls[@]} == 0 )); then
  printf 'All open pull request heads have a complete HyperFleet review.\n'
  exit 0
fi

if (( ${#pending_pulls[@]} > MAX_REVIEWS_PER_RUN )); then
  printf 'Discovery returned too many pull requests.\n' >&2
  exit 1
fi

declare -A selected_pr_numbers=()
review_pr_numbers=()
review_head_shas=()

for pull_row in "${pending_pulls[@]}"; do
  IFS=$'\t' read -r pr_number head_sha extra_value <<<"$pull_row"
  if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]] ||
    [[ ! "$head_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] ||
    [[ -n "${extra_value:-}" ]]; then
    printf 'Discovery returned invalid pull request data.\n' >&2
    exit 1
  fi
  if [[ -n "${selected_pr_numbers[$pr_number]:-}" ]]; then
    printf 'Discovery returned pull request %s more than one time.\n' \
      "$pr_number" >&2
    exit 1
  fi
  selected_pr_numbers[$pr_number]=true
  review_pr_numbers+=("$pr_number")
  review_head_shas+=("$head_sha")
done

review_pids=()
for index in "${!review_pr_numbers[@]}"; do
  run_review "${review_pr_numbers[$index]}" "${review_head_shas[$index]}" &
  review_pids+=("$!")
  active_pids=("${review_pids[@]}")
done

failed_review_count=0
for index in "${!review_pids[@]}"; do
  if wait "${review_pids[$index]}"; then
    printf 'Review worker for %s#%s succeeded.\n' \
      "$REPOSITORY" "${review_pr_numbers[$index]}"
  else
    printf 'Review worker for %s#%s failed.\n' \
      "$REPOSITORY" "${review_pr_numbers[$index]}" >&2
    ((failed_review_count += 1))
  fi
  active_pids[index]=""
done
active_pids=()

printf 'HyperFleet review worker summary: %s started and %s failed.\n' \
  "${#review_pids[@]}" "$failed_review_count"

if (( failed_review_count != 0 )); then
  exit 1
fi
