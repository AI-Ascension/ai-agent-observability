#!/usr/bin/env bash
# OTel installer common helpers — shared guards, bounds, hashing and timeout accounting
#
# Extracted verbatim from deploy/install-otel-health-probe.sh by the
# behavior-preserving module split in issue #45. This file is sourced by the
# installer coordinator and defines functions only; it is never executed
# directly.
#
# ShellCheck cannot follow the coordinator's `source` chain, so shared
# globals and helper functions appear "unused" or "unassigned" per file.
# The two diagnostics below are disabled file-wide for that reason.
# shellcheck disable=SC2034,SC2154

fail() {
  printf 'otel installer: %s\n' "$1" >&2
  exit 1
}

canonical_health_status() {
  local value="${1:-}"
  case "$value" in
    ''|missing|null) printf '%s\n' missing ;;
    healthy|unhealthy|starting) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

validate_candidate_config_user() {
  [[ "$expected_candidate_config_user" == 10001:10001 ]] || \
    fail 'OTEL_EXPECTED_CANDIDATE_CONFIG_USER must remain 10001:10001'
  [[ "$1" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || \
    fail 'candidate Config.User must be an explicit UID:GID pair'
  [[ "$1" == "$expected_candidate_config_user" ]] || \
    fail "candidate Config.User must be $expected_candidate_config_user"
}

need_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

require_hash() {
  local name="$1"
  local path="$2"
  local expected="${!name:-}"
  local actual

  need_value "$name"
  [[ -f "$path" ]] || fail "missing $path"
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || fail "$path hash does not match $name"
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

remaining_timeout() {
  local requested="$1"
  local remaining available
  remaining=$((operation_deadline - SECONDS))
  (( remaining > timeout_kill_after_seconds )) || fail "aggregate operation timeout exceeded"
  available=$((remaining - timeout_kill_after_seconds))
  (( requested < available )) && printf '%s\n' "$requested" || printf '%s\n' "$available"
}

rollback_remaining_timeout() {
  local requested="$1"
  local remaining available
  remaining=$((rollback_deadline - SECONDS))
  (( remaining > timeout_kill_after_seconds )) || return 1
  available=$((remaining - timeout_kill_after_seconds))
  (( requested < available )) && printf '%s\n' "$requested" || printf '%s\n' "$available"
}

operation_timeout() {
  if [[ "$rollback_active" == true ]]; then
    rollback_remaining_timeout "$1"
  else
    remaining_timeout "$1"
  fi
}

# Keep engine operations bounded and distinguish timeout from a normal command
# failure. Stdout and stderr are capped separately; only stdout is returned so
# engine diagnostics cannot contaminate identity values or echo secrets.
bounded_capture() {
  local label="$1"
  local requested="$2"
  shift 2
  local output error status seconds file_limit bytes error_bytes
  output="$(mktemp)"
  error="$(mktemp)"
  if ! seconds="$(operation_timeout "$requested")"; then
    rm -f -- "$output" "$error"
    printf 'otel installer: %s exceeded its aggregate timeout budget\n' "$label" >&2
    return 124
  fi
  file_limit=$(( (max_capture_bytes + 511) / 512 ))
  # No --foreground means timeout owns a process group and can terminate
  # grandchildren. ulimit caps inherited stdout and stderr before either temp
  # file grows.
  if timeout --kill-after="${timeout_kill_after_seconds}s" "${seconds}s" \
      bash -c 'ulimit -f "$1" || exit 125; shift; exec "$@"' _ "$file_limit" "$@" >"$output" 2>"$error"; then
    bytes="$(wc -c <"$output")"
    error_bytes="$(wc -c <"$error")"
    if (( bytes > max_capture_bytes || error_bytes > max_capture_bytes )); then
      rm -f -- "$output" "$error"
      printf 'otel installer: %s exceeded the %s-byte capture limit\n' "$label" "$max_capture_bytes" >&2
      return 125
    fi
    cat -- "$output"
    rm -f -- "$output" "$error"
    return 0
  else
    status=$?
  fi
  rm -f -- "$output" "$error"
  if [[ "$status" == 124 || "$status" == 137 ]]; then
    printf 'otel installer: %s timed out after %ss\n' "$label" "$seconds" >&2
    return 124
  fi
  if [[ "$status" == 125 || "$status" == 153 ]]; then
    printf 'otel installer: %s exceeded the %s-byte capture limit\n' "$label" "$max_capture_bytes" >&2
    return 125
  fi
  printf 'otel installer: %s failed (exit %s)\n' "$label" "$status" >&2
  return "$status"
}

bounded_run() {
  local label="$1"
  local requested="$2"
  shift 2
  local status
  if bounded_capture "$label" "$requested" "$@" >/dev/null; then
    return 0
  else
    status=$?
  fi
  return "$status"
}
