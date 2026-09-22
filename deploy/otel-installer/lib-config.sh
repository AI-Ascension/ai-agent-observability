#!/usr/bin/env bash
# OTel installer configuration helpers — dotenv/collector-config parsing and environment identity
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

canonical_expected_list() {
  local name="$1"
  need_value "$name"
  python3 - "$name" "${!name}" <<'PY'
import sys

name, raw = sys.argv[1:]
values = [part.strip() for part in raw.split(",")]
if not values or any(not value or any(ch.isspace() for ch in value) for value in values):
    raise SystemExit(f"{name} contains an empty or malformed entry")
if len(values) != len(set(values)):
    raise SystemExit(f"{name} contains duplicate entries")
sys.stdout.write("\n".join(sorted(values)) + "\n")
PY
}
dotenv_value() {
  local key="$1"
  local value
  value="$(awk -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, key "=") == 1) {
        count++
        value = substr(line, length(key) + 2)
      }
    }
    END { if (count != 1) exit 2; print value }
  ' "$env_file")" || fail "environment key $key is missing or duplicated"
  if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] ||
     [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}
verify_env_text() {
  local env_text="$1"
  local env_name
  for env_name in "${expected_env_names[@]}"; do
    printf '%s\n' "$env_text" | awk -F= -v key="$env_name" -v expected="${expected_env[$env_name]}" \
      '$1 == key { count++; if ($0 != key "=" expected) bad=1 }
       END { exit (count == 1 && !bad) ? 0 : 1 }' || return 1
  done
}

env_identity() {
  local env_text="$1"
  local env_name
  for env_name in "${expected_env_names[@]}"; do
    printf '%s\n' "$env_text" | awk -F= -v key="$env_name" -v expected="${expected_env[$env_name]}" \
      '$1 == key && $0 == key "=" expected { print $0; found++ }
       END { if (found != 1) exit 1 }' || return 1
  done | LC_ALL=C sort | sha256sum | awk '{print $1}'
}
env_identity_all() {
  local env_text="$1"
  # Keep the complete container environment comparison secret-safe: only the
  # digest is retained or reported, never the values themselves.
  printf '%s\n' "$env_text" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}
