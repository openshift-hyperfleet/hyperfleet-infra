#!/usr/bin/env bash
# SC2016: the single-quoted script expands inside the sandbox, not here.
# shellcheck disable=SC2016
# Shared runtime library for OpenShell agents.
# Source this file after `set -Eeuo pipefail` in an agent runner.
# Expects GATEWAY_NAME, GATEWAY_ENDPOINT, OIDC_ISSUER, OIDC_CLIENT_ID,
# OIDC_AUDIENCE, GATEWAY_LOGIN_REFRESH_SECONDS in the caller's environment.

is_valid_sandbox_name() {
  local sandbox_name=$1

  [[ "$sandbox_name" =~ ^[a-z0-9]([a-z0-9-]{0,17}[a-z0-9])?$ ]] &&
    [[ "$sandbox_name" != *--* ]]
}

openshell_for() {
  local root=$1
  shift

  env \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    XDG_STATE_HOME="$root/state" \
    openshell "$@"
}

# Add the gateway config and record the time so renew_gateway_login can
# measure elapsed time from first configuration. Does NOT log in; login is
# performed lazily by renew_gateway_login or by openshell commands that carry
# the OIDC client secret in the environment.
configure_gateway() {
  local root=$1

  mkdir -p "$root/home" "$root/config" "$root/state"
  openshell_for "$root" gateway add "$GATEWAY_ENDPOINT" \
    --name "$GATEWAY_NAME" \
    --oidc-issuer "$OIDC_ISSUER" \
    --oidc-client-id "$OIDC_CLIENT_ID" \
    --oidc-audience "$OIDC_AUDIENCE" \
    >/dev/null
  gateway_login_at=$SECONDS
}

# Refresh the gateway session if GATEWAY_LOGIN_REFRESH_SECONDS has elapsed
# since the last login, or if force=true is passed. Sets gateway_login_at on
# success.
renew_gateway_login() {
  local root=$1
  local force=${2:-false}
  local login_output

  if [[ "$force" != true ]] && (( gateway_login_at > 0 )) &&
    (( SECONDS - gateway_login_at < GATEWAY_LOGIN_REFRESH_SECONDS )); then
    return 0
  fi

  if ! login_output=$(openshell_for "$root" gateway login \
    "$GATEWAY_NAME" 2>&1); then
    printf 'Cannot renew the OpenShell gateway login.\n' >&2
    printf '%s\n' "$login_output" >&2
    return 1
  fi
  gateway_login_at=$SECONDS
}

# List sandboxes matching SELECTOR under ROOT and delete each one. Returns 1
# if the gateway reports an invalid sandbox name; otherwise exits with the
# last delete status.
cleanup_stale_sandboxes() {
  local root=$1
  local selector=$2
  local stale_list name

  if ! stale_list=$(openshell_for "$root" sandbox list \
    --selector "$selector" --names); then
    printf 'Cannot list sandboxes with selector %s.\n' "$selector" >&2
    return 1
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! is_valid_sandbox_name "$name"; then
      printf 'Gateway returned an invalid sandbox name.\n' >&2
      return 1
    fi
    printf 'Deleting stale sandbox %s.\n' "$name"
    openshell_for "$root" sandbox delete "$name"
  done <<<"$stale_list"
}

# Poll SANDBOX_NAME under ROOT for a detached work process status file.
# The detached process writes its exit code as a plain integer to
# WORK_STATUS_FILE when done; before that the file does not exist. On
# completion, reads WORK_LOG_FILE from the sandbox to stdout and returns the
# remote exit code. Returns 124 on timeout. Requires renew_gateway_login and
# gateway_login_at in the caller's scope.
wait_for_detached_work() {
  local root=$1
  local sandbox_name=$2
  local work_log_file=$3
  local work_status_file=$4
  local timeout_seconds=$5
  local poll_seconds=${6:-15}
  local local_log_file="/tmp/$sandbox_name-work.log"
  local work_deadline=$((SECONDS + timeout_seconds))
  local remote_status poll_status remaining_seconds sleep_seconds

  while (( SECONDS < work_deadline )); do
    if ! renew_gateway_login "$root"; then
      gateway_login_at=0
    else
      set +e
      remote_status=$(openshell_for "$root" sandbox exec \
        --name "$sandbox_name" \
        --timeout 30 \
        --no-tty \
        /usr/bin/bash -c \
        'if [[ -r "$1" ]]; then /usr/bin/cat "$1"; else printf "running\n"; fi' \
        bash "$work_status_file" 2>&1)
      poll_status=$?
      set -e

      if (( poll_status != 0 )); then
        printf 'Cannot read work status for sandbox %s. Retry.\n' \
          "$sandbox_name" >&2
        printf '%s\n' "$remote_status" >&2
        gateway_login_at=0
      elif [[ "$remote_status" == running ]]; then
        :
      elif [[ "$remote_status" =~ ^[0-9]+$ ]] && (( remote_status <= 255 )); then
        while (( SECONDS < work_deadline )); do
          if renew_gateway_login "$root" true &&
            openshell_for "$root" sandbox exec \
              --name "$sandbox_name" \
              --timeout 60 \
              --no-tty \
              /usr/bin/cat "$work_log_file" >"$local_log_file"; then
            cat "$local_log_file"
            return "$remote_status"
          fi
          gateway_login_at=0
          printf 'Cannot read work log for sandbox %s. Retry.\n' \
            "$sandbox_name" >&2
          sleep "$poll_seconds"
        done
      else
        printf 'Sandbox %s returned an invalid work status.\n' \
          "$sandbox_name" >&2
        return 1
      fi
    fi

    remaining_seconds=$((work_deadline - SECONDS))
    (( remaining_seconds <= 0 )) && break
    sleep_seconds=$poll_seconds
    (( sleep_seconds > remaining_seconds )) && sleep_seconds=$remaining_seconds
    sleep "$sleep_seconds"
  done

  printf 'The work in sandbox %s did not finish in %s seconds.\n' \
    "$sandbox_name" "$timeout_seconds" >&2
  return 124
}
