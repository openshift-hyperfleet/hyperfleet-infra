#!/usr/bin/env bash
# gh wrapper for the review sandbox. The sandbox proxy drops connections now
# and then ("EOF", "connection reset"). Retry such transport errors for every
# gh call except POST requests, which could create duplicates. Claude Code and
# the review scripts find this wrapper first on PATH.

set -u

real_gh=${HFREVIEW_REAL_GH:-}
for candidate in /usr/local/bin/gh /usr/bin/gh; do
  [[ -z "$real_gh" ]] || break
  if [[ -x "$candidate" ]]; then
    real_gh=$candidate
    break
  fi
done
if [[ -z "$real_gh" ]]; then
  printf 'gh is not installed in the sandbox.\n' >&2
  exit 127
fi

max_attempts=${GH_API_MAX_ATTEMPTS:-4}
delay=${GH_API_RETRY_DELAY_SECONDS:-3}

is_post=false
previous=""
for argument in "$@"; do
  if [[ "$previous" == --method || "$previous" == -X ]] && [[ "${argument^^}" == POST ]]; then
    is_post=true
  fi
  previous=$argument
done

# Keep stdin usable by the real command on the first attempt only; a retry
# cannot replay piped input, so piped POST bodies are never retried.
error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT
attempt=1
while true; do
  "$real_gh" "$@" 2>"$error_file"
  status=$?
  if (( status == 0 )) || [[ "$is_post" == true ]] || (( attempt >= max_attempts )) ||
    ! grep --quiet --extended-regexp --ignore-case \
      'EOF|connection reset|connection refused|broken pipe|unexpected end|timeout' "$error_file"; then
    cat "$error_file" >&2
    exit "$status"
  fi
  printf 'gh: transient transport error (attempt %s of %s), retry in %ss: %s\n' \
    "$attempt" "$max_attempts" "$delay" "$(head -1 "$error_file")" >&2
  sleep "$delay"
  attempt=$((attempt + 1))
done
