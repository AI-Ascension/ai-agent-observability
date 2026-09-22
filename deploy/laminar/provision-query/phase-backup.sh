#!/usr/bin/env bash
# Backup phase — capture exact restorable state and prepare credentials before mutation
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the ordering globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

# Capture a SQL-safe restoration statement and exact row metadata for the
# existing operator row in one locked PostgreSQL transaction. An absent row is
# recorded as an empty backup. Hex encoding keeps the SQL result to one safe
# line even when a stored text value contains a delimiter or newline.
cat >"$db_backup_meta_sql" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
DO \$\$
DECLARE
  operator_rows integer;
BEGIN
  PERFORM id FROM projects
   WHERE id = '$project_id'::uuid
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'configured Laminar project does not exist';
  END IF;
  PERFORM id FROM project_api_keys
   WHERE project_id = '$project_id'::uuid
     AND name = '$operator_key_name'
   FOR UPDATE;
  GET DIAGNOSTICS operator_rows = ROW_COUNT;
  IF operator_rows > 1 THEN
    RAISE EXCEPTION 'operator query key has duplicate rows';
  END IF;
END
\$\$;
SELECT 'backup_sql_hex=' || COALESCE((
  SELECT encode(convert_to(format(
    'INSERT INTO project_api_keys (id, name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value, created_at) VALUES (%L, %L, %L, %L, %L, %L, %L, %L, %L, %L);',
    id, name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value, created_at), 'UTF8'), 'hex')
  FROM project_api_keys
  WHERE project_id = '$project_id'::uuid
    AND name = '$operator_key_name'
), '');
SELECT 'backup_meta=' || COALESCE((
  SELECT id::text || E'\t' || md5(row_to_json(pak)::text)
  FROM project_api_keys AS pak
  WHERE project_id = '$project_id'::uuid
    AND name = '$operator_key_name'
), '');
COMMIT;
SQL
chmod 600 "$db_backup_meta_sql"
if ! run_psql_file "$db_backup_meta_sql"; then
  die 1 'could not capture the existing operator key row and metadata'
fi
python3 - "$sql_output" "$db_backup_sql" "$db_backup_meta" <<'PY'
import pathlib
import re
import sys

source, backup_sql, backup_meta = map(pathlib.Path, sys.argv[1:])
lines = source.read_text().splitlines()
if len(lines) != 2:
    raise SystemExit("operator backup transaction returned an unexpected row count")
markers = {}
for line in lines:
    name, separator, value = line.partition("=")
    if not separator or name in markers:
        raise SystemExit("operator backup transaction returned malformed markers")
    markers[name] = value
if set(markers) != {"backup_sql_hex", "backup_meta"}:
    raise SystemExit("operator backup transaction returned unexpected markers")
encoded = markers["backup_sql_hex"]
if not re.fullmatch(r"[0-9a-fA-F]*", encoded):
    raise SystemExit("operator backup SQL encoding was malformed")
try:
    backup_sql.write_bytes(bytes.fromhex(encoded))
except ValueError as error:
    raise SystemExit("operator backup SQL encoding was malformed") from error
metadata = markers["backup_meta"]
if bool(encoded) != bool(metadata):
    raise SystemExit("operator backup transaction returned an inconsistent row snapshot")
if metadata:
    fields = metadata.split("\t")
    if len(fields) != 2 or not re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        fields[0],
    ) or not re.fullmatch(r"[0-9a-fA-F]{32}", fields[1]):
        raise SystemExit("operator backup metadata was malformed")
    backup_meta.write_text(metadata + "\n", encoding="utf-8")
else:
    backup_meta.write_text("", encoding="utf-8")
for path in (backup_sql, backup_meta):
    path.chmod(0o600)
PY
operator_backup_id=''
operator_backup_row_hash=''
if [[ -s "$db_backup_meta" ]]; then
  IFS=$'\t' read -r operator_backup_id operator_backup_row_hash <"$db_backup_meta"
fi

# Protect the existing local key and .env before any persistent mutation.
cp -p "$env_file" "$env_backup"
chmod 600 "$env_backup"
if [[ -e "$query_key_file" ]]; then
  if [[ ! -f "$query_key_file" || -L "$query_key_file" ]]; then
    die 64 'existing query key path is not a regular file'
  fi
  key_mode="$(stat -c '%a' "$query_key_file")"
  key_owner="$(stat -c '%u' "$query_key_file")"
  if [[ "$key_mode" != 600 || "$key_owner" != 0 ]]; then
    die 64 'existing query key must be root-owned mode 0600'
  fi
  cp -p "$query_key_file" "$key_backup"
  printf '%s\n' present >"$key_backup_state"
else
  printf '%s\n' absent >"$key_backup_state"
fi
chmod 600 "$key_backup_state"

query_key="$(openssl rand -hex 32)"
query_key_hash="$(printf '%s' "$query_key" | openssl dgst -sha3-256 -r | awk '{print $1}')"
query_key_prefix="$(printf '%s' "$query_key" | cut -c1-4)"
query_key_suffix="$(printf '%s' "$query_key" | tail -c 4)"
query_shorthand="$(printf '%s...%s' "$query_key_prefix" "$query_key_suffix")"
operator_insert_hex="$(openssl rand -hex 16)"
if [[ ! "$operator_insert_hex" =~ ^[[:xdigit:]]{32}$ ]]; then
  die 69 'generated PostgreSQL operator row identity is invalid'
fi
operator_insert_id="${operator_insert_hex:0:8}-${operator_insert_hex:8:4}-${operator_insert_hex:12:4}-${operator_insert_hex:16:4}-${operator_insert_hex:20:12}"
clickhouse_ro_password="$(openssl rand -hex 32)"
query_key_length="$(printf '%s' "$query_key" | wc -c)"
query_hash_length="$(printf '%s' "$query_key_hash" | wc -c)"
ro_password_length="$(printf '%s' "$clickhouse_ro_password" | wc -c)"
if [[ "$query_key_length" -ne 64 || "$query_hash_length" -ne 64 || "$ro_password_length" -ne 64 ]]; then
  die 69 'generated credential did not meet the required bound'
fi
printf '%s\n' "$query_key" >"$new_key_file"
chmod 600 "$new_key_file"
cp -p "$new_key_file" "$candidate_key_evidence"
chmod 600 "$candidate_key_evidence"
cat >"$pg_reconciliation_evidence" <<EOF
project_id=$project_id
candidate_id=$operator_insert_id
candidate_key=$candidate_key_evidence
operator_name=$operator_key_name
expected_shorthand=$query_shorthand
expected_hash=$query_key_hash
expected_is_ingest_only=false
expected_user_id=NULL
expected_expires_at=NULL
expected_value_empty=true
EOF
chmod 600 "$pg_reconciliation_evidence"

cat >"$ch_sql" <<SQL
CREATE USER \`$ro_user\`
  IDENTIFIED WITH sha256_password BY '$clickhouse_ro_password';
SQL
chmod 600 "$ch_sql"

cat >"$ch_grant_sql" <<SQL
ALTER USER \`$ro_user\`
  DEFAULT ROLE NONE
  SETTINGS
    readonly = 1,
    max_execution_time = 30,
    max_memory_usage = 268435456,
    max_result_rows = 10000,
    max_result_bytes = 16777216,
    max_threads = 2;
GRANT SELECT ON default.spans TO \`$ro_user\`;
GRANT SELECT ON default.spans_v0 TO \`$ro_user\`;
SQL
chmod 600 "$ch_grant_sql"

cat >"$ch_ro_config" <<XML
<config><host>127.0.0.1</host><user>$ro_user</user><password>$clickhouse_ro_password</password></config>
XML
chmod 600 "$ch_ro_config"

# All preconditions and backups are complete. From this point onward every
# persistent write has a compensation path and a deterministic rollback order.
ch_mutation_attempted=false
ch_user_created=false
ch_user_id=''
retain_ch_ownership_evidence=false
pg_mutation_attempted=false
pg_mutation_committed=false
pg_inserted_id="$operator_insert_id"
pg_inserted_row_hash=''
pg_reconciliation_result=none
key_mutation_attempted=false
env_mutation_attempted=false
