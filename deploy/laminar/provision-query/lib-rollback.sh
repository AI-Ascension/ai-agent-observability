#!/usr/bin/env bash
# Deterministic compensation — ordered rollback across env, key, PostgreSQL, ClickHouse
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the shared globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

rollback() {
  local status="$?"
  local rollback_failed=false
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' 'provisioning failed; starting deterministic compensation' >&2
    if [[ "$env_mutation_attempted" == true ]]; then
      if ! cp -p "$env_backup" "$env_file" || ! chmod 600 "$env_file"; then
        rollback_failed=true
        printf '%s\n' 'rollback failed while restoring .env' >&2
      fi
    fi
    if [[ "$key_mutation_attempted" == true ]]; then
      if [[ "$(cat "$key_backup_state")" == present ]]; then
        if ! cp -p "$key_backup" "$query_key_file" || ! chmod 600 "$query_key_file"; then
          rollback_failed=true
          printf '%s\n' 'rollback failed while restoring the prior query key' >&2
        fi
      elif ! rm -f "$query_key_file"; then
        rollback_failed=true
        printf '%s\n' 'rollback failed while removing the staged query key' >&2
      fi
    fi
    if [[ "$pg_mutation_attempted" == true ]]; then
      if [[ "$pg_mutation_committed" == unknown ]]; then
        if ! reconcile_unknown_postgres_commit; then
          retain_pg_reconciliation_artifacts 'PostgreSQL transaction outcome could not be reconciled'
          rollback_failed=true
          printf '%s\n' 'PostgreSQL transaction outcome is unknown and the exact candidate row could not be reconciled; manual review is required' >&2
        fi
      fi
      if [[ "$pg_mutation_committed" == true ]]; then
        if ! restore_postgres_operator_row; then
          retain_pg_reconciliation_artifacts 'PostgreSQL candidate row could not be restored exactly'
          rollback_failed=true
          printf '%s\n' 'rollback failed while restoring the prior PostgreSQL operator key' >&2
        fi
      elif [[ "$pg_reconciliation_result" == absent ]]; then
        printf '%s\n' 'PostgreSQL exact candidate row is absent; commit outcome remains unknown and no exact row compensation was attempted' >&2
      fi
    fi
    if [[ "$ch_mutation_attempted" == true ]]; then
      if [[ "$ch_user_created" == true ]]; then
        if ! drop_owned_clickhouse_user; then
          retain_ch_ownership_evidence=true
          rollback_failed=true
          printf 'refusing to drop ClickHouse user after ownership check failed; reconcile user=%s id=%s evidence=%s password_config=%s\n' \
            "$ro_user" "${ch_user_id:-unknown}" "$ch_ownership_evidence" "$ch_ro_config" >&2
        fi
      elif ! run_clickhouse_query "$ch_config_path" \
        "SELECT name FROM system.users WHERE name = '$ro_user' FORMAT TSV"; then
        rollback_failed=true
        printf '%s\n' 'rollback could not determine whether a foreign ClickHouse user appeared' >&2
      elif grep -Fxq "$ro_user" "$ch_output"; then
        rollback_failed=true
        printf '%s\n' 'refusing to drop a ClickHouse user after an ambiguous CREATE failure; reconcile it manually' >&2
      fi
    fi
    if [[ "$rollback_failed" == true && "$pg_mutation_committed" == unknown ]]; then
      retain_pg_reconciliation_artifacts 'another compensation step failed while PostgreSQL outcome remained unknown'
    fi
    printf 'rollback_env_backup=%s\n' "$env_backup" >&2
    printf 'rollback_key_backup=%s\n' "$key_backup" >&2
    printf 'rollback_db_backup=%s\n' "$db_backup_sql" >&2
    if [[ "$retain_pg_reconciliation_evidence" == true ]]; then
      printf 'rollback_pg_candidate_key=%s\n' "$candidate_key_evidence" >&2
      printf 'rollback_pg_reconciliation_evidence=%s\n' \
        "$pg_reconciliation_evidence" >&2
      printf 'rollback_pg_reconciliation_sql=%s\n' "$db_reconcile_sql" >&2
    fi
    if [[ "$rollback_failed" == true ]]; then
      printf '%s\n' 'automatic compensation was incomplete; keep the backups and reconcile by exact project/container identity' >&2
      cleanup
      exit 70
    fi
  fi
  cleanup
  exit "$status"
}
