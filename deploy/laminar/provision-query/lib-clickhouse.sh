#!/usr/bin/env bash
# ClickHouse probes — writer/read-only query helper and guarded user drop
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the shared globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

run_clickhouse_query() {
  local config_path="$1"
  local query="$2"
  : >"$ch_output"
  : >"$ch_error"
  if ! podman exec -i "$ch_container" clickhouse-client \
    --config-file "$config_path" --query "$query" \
    >"$ch_output" 2>"$ch_error"; then
    return 1
  fi
  return 0
}

drop_owned_clickhouse_user() {
  local current_user_id
  if ! run_clickhouse_query "$ch_config_path" \
    "SELECT id FROM system.users WHERE name = '$ro_user' FORMAT TSV"; then
    return 1
  fi
  current_user_id="$(awk 'NF { print $1; exit }' "$ch_output")"
  if [[ -z "$current_user_id" || "$current_user_id" != "$ch_user_id" ]]; then
    return 1
  fi
  if ! run_clickhouse_query "$ch_ro_config_path" \
    "SELECT 1 FORMAT TSV"; then
    return 1
  fi
  run_clickhouse_query "$ch_config_path" \
    "DROP USER IF EXISTS \`$ro_user\`"
}
