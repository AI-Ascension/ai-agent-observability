#!/usr/bin/env bash
# PostgreSQL reconciliation — retain evidence, classify commit, restore row
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the shared globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

retain_pg_reconciliation_artifacts() {
  local reason="$1"
  retain_pg_reconciliation_evidence=true
  printf 'retention_reason=%s\n' "$reason" >>"$pg_reconciliation_evidence" 2>/dev/null || true
}

reconcile_unknown_postgres_commit() {
  # A client-side PostgreSQL failure after COMMIT leaves the commit outcome
  # unknown. Lock the project and candidate row, then classify only the exact
  # preassigned row. A changed or foreign row is retained for manual review.
  cat >"$db_reconcile_sql" <<SQL
BEGIN;
DO \$\$
BEGIN
  PERFORM id FROM projects
   WHERE id = '$project_id'::uuid
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'configured Laminar project disappeared during commit reconciliation';
  END IF;
  PERFORM id FROM project_api_keys
   WHERE id = '$pg_inserted_id'::uuid
   FOR UPDATE;
END
\$\$;
SELECT CASE
  WHEN NOT EXISTS (
    SELECT 1 FROM project_api_keys
     WHERE id = '$pg_inserted_id'::uuid
  ) THEN 'candidate=absent'
  WHEN EXISTS (
    SELECT 1 FROM project_api_keys
     WHERE id = '$pg_inserted_id'::uuid
       AND project_id = '$project_id'::uuid
       AND name = '$operator_key_name'
       AND shorthand = '$query_shorthand'
       AND hash = '$query_key_hash'
       AND is_ingest_only = false
       AND user_id IS NULL
       AND expires_at IS NULL
       AND value = ''
  ) THEN 'candidate=match' || E'\t' || (
    SELECT md5(row_to_json(pak)::text)
      FROM project_api_keys AS pak
     WHERE pak.id = '$pg_inserted_id'::uuid
  )
  ELSE 'candidate=mismatch'
END;
COMMIT;
SQL
  chmod 600 "$db_reconcile_sql"
  if ! run_psql_file "$db_reconcile_sql"; then
    return 1
  fi
  local candidate_meta candidate_kind candidate_hash
  candidate_meta="$(cat "$sql_output")"
  if [[ "$candidate_meta" == *$'\n'* ]]; then
    return 1
  fi
  IFS=$'\t' read -r candidate_kind candidate_hash <<<"$candidate_meta"
  case "$candidate_kind" in
    candidate=absent)
      [[ -z "$candidate_hash" ]] || return 1
      pg_mutation_committed=unknown
      pg_reconciliation_result=absent
      return 0
      ;;
    candidate=match)
      if [[ ! "$candidate_hash" =~ ^[[:xdigit:]]{32}$ ]]; then
        return 1
      fi
      pg_inserted_row_hash="$candidate_hash"
      pg_mutation_committed=true
      pg_reconciliation_result=match
      return 0
      ;;
    candidate=mismatch)
      pg_reconciliation_result=mismatch
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

restore_postgres_operator_row() {
  if [[ -z "$pg_inserted_id" || -z "$pg_inserted_row_hash" ]]; then
    return 1
  fi
  {
    cat <<SQL
BEGIN;
DO \$\$
DECLARE
  current_row_hash text;
BEGIN
  PERFORM id FROM projects
   WHERE id = '$project_id'::uuid
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'configured Laminar project disappeared during rollback';
  END IF;
  SELECT md5(row_to_json(pak)::text)
    INTO current_row_hash
    FROM project_api_keys AS pak
   WHERE pak.id = '$pg_inserted_id'::uuid
     AND pak.project_id = '$project_id'::uuid
     AND pak.name = '$operator_key_name'
   FOR UPDATE;
  IF current_row_hash IS DISTINCT FROM '$pg_inserted_row_hash' THEN
    RAISE EXCEPTION 'helper PostgreSQL operator row changed before rollback';
  END IF;
END
\$\$;
DELETE FROM project_api_keys AS pak
 WHERE pak.id = '$pg_inserted_id'::uuid
   AND pak.project_id = '$project_id'::uuid
   AND pak.name = '$operator_key_name'
   AND md5(row_to_json(pak)::text) = '$pg_inserted_row_hash';
SQL
    if [[ -s "$db_backup_sql" ]]; then
      cat "$db_backup_sql"
    fi
    if [[ -n "$operator_backup_id" ]]; then
      cat <<SQL
DO \$\$
DECLARE
  restored_row_hash text;
BEGIN
  SELECT md5(row_to_json(pak)::text)
    INTO restored_row_hash
   FROM project_api_keys AS pak
   WHERE pak.id = '$operator_backup_id'::uuid
     AND pak.project_id = '$project_id'::uuid
     AND pak.name = '$operator_key_name'
   FOR UPDATE;
  IF restored_row_hash IS DISTINCT FROM '$operator_backup_row_hash' THEN
    RAISE EXCEPTION 'prior PostgreSQL operator row was not restored exactly';
  END IF;
END
\$\$;
SQL
    else
      cat <<SQL
DO \$\$
BEGIN
  IF EXISTS (
    SELECT 1 FROM project_api_keys
     WHERE project_id = '$project_id'::uuid
       AND name = '$operator_key_name'
  ) THEN
    RAISE EXCEPTION 'PostgreSQL operator row should be absent after rollback';
  END IF;
END
\$\$;
SQL
    fi
    cat <<SQL
COMMIT;
SQL
  } >"$db_restore_sql"
  chmod 600 "$db_restore_sql"
  run_psql_file "$db_restore_sql"
}
