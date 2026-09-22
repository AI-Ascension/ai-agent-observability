#!/usr/bin/env bash
# Provisioning cleanup trap — remove staged private files and container paths
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the shared globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

cleanup() {
  rm -f "$sql_file" "$sql_output" "$sql_error" "$db_preflight_sql" \
    "$db_preflight_output" "$db_backup_meta_sql" \
    "$ch_config" "$ch_sql" \
    "$ch_grant_sql" "$ch_output" "$ch_error" "$env_fragment" \
    "$new_key_file" "$pgpass_file"
  if [[ "$retain_pg_reconciliation_evidence" != true ]]; then
    rm -f "$db_reconcile_sql" "$candidate_key_evidence" \
      "$pg_reconciliation_evidence"
  fi
  if [[ "$retain_ch_ownership_evidence" != true ]]; then
    rm -f "$ch_ro_config" "$ch_ownership_evidence"
  fi
  podman exec "$ch_container" rm -f "$ch_config_path" "$ch_ro_config_path" \
    >/dev/null 2>&1 || true
  podman exec "$pg_container" rm -f "$pgpass_path" >/dev/null 2>&1 || true
}
