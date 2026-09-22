#!/usr/bin/env bash
# Mutation phase — install state under the ordered compensation trap
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the ordering globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

trap rollback EXIT

# Install the protected key before the database commit. This ensures that a
# process interruption cannot leave a committed database hash with no durable
# copy of the corresponding secret.
key_mutation_attempted=true
mv -f "$new_key_file" "$query_key_file"
chmod 600 "$query_key_file"
chown root:root "$query_key_file"

# The query-key transaction locks the project first, then locks and compares
# the exact backed-up operator row before replacing it. It has no CREATE USER
# side effects. The row ID is assigned before the transaction so a lost
# response can be reconciled without a name-based delete.
{
  cat <<SQL
BEGIN;
DO \$\$
DECLARE
  current_id uuid;
  current_row_hash text;
BEGIN
  PERFORM id FROM projects
   WHERE id = '$project_id'::uuid
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'configured Laminar project does not exist';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM project_api_keys
    WHERE project_id = '$project_id'::uuid
      AND is_ingest_only = true
  ) THEN
    RAISE EXCEPTION 'Collector ingest-only key row is missing';
  END IF;
  SELECT pak.id, md5(row_to_json(pak)::text)
    INTO current_id, current_row_hash
    FROM project_api_keys AS pak
   WHERE pak.project_id = '$project_id'::uuid
     AND pak.name = '$operator_key_name'
   FOR UPDATE;
SQL
  if [[ -n "$operator_backup_id" ]]; then
    cat <<SQL
  IF NOT FOUND
     OR current_id IS DISTINCT FROM '$operator_backup_id'::uuid
     OR current_row_hash IS DISTINCT FROM '$operator_backup_row_hash' THEN
    RAISE EXCEPTION 'operator key changed since its exact backup';
  END IF;
END
\$\$;
DELETE FROM project_api_keys AS pak
 WHERE pak.id = '$operator_backup_id'::uuid
   AND pak.project_id = '$project_id'::uuid
   AND pak.name = '$operator_key_name'
   AND md5(row_to_json(pak)::text) = '$operator_backup_row_hash';
SQL
  else
    cat <<SQL
  IF FOUND THEN
    RAISE EXCEPTION 'operator key appeared since the exact backup';
  END IF;
END
\$\$;
SQL
  fi
  cat <<SQL
WITH inserted AS (
  INSERT INTO project_api_keys
    (id, name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value)
  VALUES
    ('$operator_insert_id'::uuid, '$operator_key_name', '$project_id'::uuid, '$query_shorthand',
     '$query_key_hash', false, NULL, NULL, '')
  RETURNING *
)
SELECT 'inserted=' || inserted.id::text || E'\t' || md5(row_to_json(inserted)::text)
FROM inserted;
DO \$\$
BEGIN
  IF (SELECT count(*) FROM project_api_keys
      WHERE project_id = '$project_id'::uuid
        AND is_ingest_only = true) < 1
     OR (SELECT count(*) FROM project_api_keys
         WHERE project_id = '$project_id'::uuid
         AND name = '$operator_key_name'
         AND is_ingest_only = false) <> 1 THEN
    RAISE EXCEPTION 'operator key transaction failed its postcondition';
  END IF;
END
\$\$;
COMMIT;
SQL
} >"$sql_file"
chmod 600 "$sql_file"

pg_mutation_attempted=true
if ! run_psql_file "$sql_file"; then
  pg_mutation_committed=unknown
  die 1 'Laminar operator key transaction failed; raw database output remains root-private'
fi
pg_mutation_committed=unknown
inserted_meta="$(python3 - "$sql_output" "$operator_insert_id" <<'PY'
import pathlib
import re
import sys

lines = [line for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line]
expected_id = sys.argv[2]
if len(lines) != 1:
    raise SystemExit("operator transaction did not return exactly one inserted-row marker")
prefix, separator, row_hash = lines[0].partition("\t")
if not prefix.startswith("inserted=") or not separator:
    raise SystemExit("operator transaction returned an invalid inserted-row marker")
row_id = prefix.removeprefix("inserted=")
if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", row_id):
    raise SystemExit("inserted operator row ID is not a canonical UUID")
if row_id.lower() != expected_id.lower():
    raise SystemExit("inserted operator row ID did not match the preassigned identity")
if not re.fullmatch(r"[0-9a-fA-F]{32}", row_hash):
    raise SystemExit("inserted operator row digest is malformed")
print(f"{row_id}\t{row_hash}")
PY
)" || die 69 'operator transaction marker was unavailable; manual reconciliation is required'
IFS=$'\t' read -r pg_inserted_id pg_inserted_row_hash <<<"$inserted_meta"
pg_mutation_committed=true
pg_reconciliation_result=match
printf '%s\n' 'operator query key transaction=committed collector_key=preserved'

# The target account was proved absent, so CREATE USER cannot overwrite a
# pre-existing account. A legacy writer alias gets a fresh nonce-qualified
# target name for every migration. CREATE runs separately from grants so the
# compensation path can verify both the ClickHouse UUID and the generated
# password before a name-based DROP. That check is intentionally conservative:
# an identity mismatch retains protected reconciliation evidence and exits 70.
# Authorized root operations must serialize this procedure with other account
# administration; the check and DROP are not an atomic ClickHouse primitive.
ch_mutation_attempted=true
if ! podman exec -i "$ch_container" clickhouse-client \
  --config-file "$ch_config_path" --multiquery <"$ch_sql" \
  >"$ch_output" 2>"$ch_error"; then
  die 1 'ClickHouse read-only user creation failed; raw output remains root-private'
fi
ch_user_created=true
cat >"$ch_ownership_evidence" <<EOF
target_user=$ro_user
target_id=unknown
password_config=$ch_ro_config
EOF
chmod 600 "$ch_ownership_evidence"
if ! podman exec -i "$ch_container" sh -c 'umask 077; cat > "$1"' sh "$ch_ro_config_path" \
  <"$ch_ro_config" >/dev/null 2>"$ch_error"; then
  die 70 'could not install protected ClickHouse ownership config; reconcile the staged account'
fi
if ! run_clickhouse_query "$ch_config_path" \
  "SELECT id FROM system.users WHERE name = '$ro_user' FORMAT TSV"; then
  die 70 'could not capture the staged ClickHouse user UUID; reconcile the staged account'
fi
ch_user_id="$(awk 'NF { print $1; exit }' "$ch_output")"
if [[ ! "$ch_user_id" =~ $uuid_pattern ]]; then
  die 70 'staged ClickHouse user UUID is unavailable; reconcile the staged account'
fi
cat >"$ch_ownership_evidence" <<EOF
target_user=$ro_user
target_id=$ch_user_id
password_config=$ch_ro_config
EOF
chmod 600 "$ch_ownership_evidence"
if ! podman exec -i "$ch_container" clickhouse-client \
  --config-file "$ch_config_path" --multiquery <"$ch_grant_sql" \
  >"$ch_output" 2>"$ch_error"; then
  die 1 'ClickHouse read-only user grants failed; raw output remains root-private'
fi

if ! run_clickhouse_query "$ch_config_path" \
  "SHOW GRANTS FOR \`$ro_user\` FORMAT TSV"; then
  die 1 'could not verify ClickHouse read-only grants'
fi
python3 - "$ch_output" "$ro_user" <<'PY'
import pathlib
import sys

lines = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
user = sys.argv[2]
required = {
    f"GRANT SELECT ON default.spans TO {user}",
    f"GRANT SELECT ON default.spans_v0 TO {user}",
}
if not required <= set(lines):
    raise SystemExit("read-only grants did not match the two exposed span objects exactly")
if any("ON *.*" in line or "WITH GRANT OPTION" in line for line in lines):
    raise SystemExit("read-only account has a broader grant than the two span objects")
PY
if ! run_clickhouse_query "$ch_config_path" \
  "SHOW CREATE USER \`$ro_user\` FORMAT TSV"; then
  die 1 'could not verify ClickHouse read-only settings'
fi
python3 - "$ch_output" "$ro_user" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
user = sys.argv[2]
for marker in (
    user,
    "DEFAULT ROLE NONE",
    "readonly = 1",
    "max_execution_time = 30",
    "max_memory_usage = 268435456",
    "max_result_rows = 10000",
    "max_result_bytes = 16777216",
    "max_threads = 2",
):
    if marker not in text:
        raise SystemExit(f"read-only account is missing setting: {marker}")
PY
if ! run_clickhouse_query "$ch_ro_config_path" \
  "SELECT 1 FROM default.spans LIMIT 1 FORMAT TSV"; then
  die 1 'read-only spans query was denied'
fi
if ! run_clickhouse_query "$ch_ro_config_path" \
  "SELECT 1 FROM default.spans_v0 LIMIT 1 FORMAT TSV"; then
  die 1 'read-only spans_v0 query was denied'
fi
printf '%s\n' 'clickhouse_readonly=verified objects=default.spans,default.spans_v0'

# Update only the two protected Compose values after both remote writes have
# passed their postconditions. The pre-change file remains available for
# rollback and audit.
printf 'CLICKHOUSE_RO_USER=%s\nCLICKHOUSE_RO_PASSWORD=%s\n' \
  "$ro_user" "$clickhouse_ro_password" >"$env_fragment"
chmod 600 "$env_fragment"
env_mutation_attempted=true
python3 - "$env_file" "$env_fragment" <<'PY'
import os
import pathlib
import tempfile
import sys

env_path = pathlib.Path(sys.argv[1])
fragment_path = pathlib.Path(sys.argv[2])
replacement = {}
for line in fragment_path.read_text().splitlines():
    key, separator, value = line.partition("=")
    if separator:
        replacement[key] = value
lines = env_path.read_text().splitlines()
seen = set()
updated = []
for line in lines:
    key, separator, _ = line.partition("=")
    if separator and key in replacement:
        updated.append(f"{key}={replacement[key]}")
        seen.add(key)
    else:
        updated.append(line)
for key, value in replacement.items():
    if key not in seen:
        updated.append(f"{key}={value}")
fd, temporary = tempfile.mkstemp(prefix=".env.query-provision.", dir=env_path.parent, text=True)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(updated) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, env_path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
chmod 600 "$env_file"
chown root:root "$env_file"

printf 'query_key_file=installed mode=0600 user=%s clickhouse_env=updated\n' "$query_key_file"
printf 'container_identity=%s image_id=%s\n' \
  "$ch_container" "$(podman inspect --format '{{.Image}}' "$ch_container")"
printf 'rollback_env_backup=%s\n' "$env_backup"
printf 'rollback_key_backup=%s\n' "$key_backup"
printf 'rollback_db_backup=%s\n' "$db_backup_sql"
printf '%s\n' 'No service restart was performed; recreate only the reviewed app-server/frontend services after inspecting the protected .env diff.'
