#!/usr/bin/env bash
set -euo pipefail

# Provision the separate Laminar operator query key and ClickHouse read-only
# account without putting a secret in process arguments, shell history, or
# evidence. All live reads and backups complete before the first persistent
# mutation. A failed mutation compensates the other systems from those
# backups. This helper is root-only and never restarts Compose.

die() {
  local status="$1"
  shift
  printf '%s\n' "$*" >&2
  exit "$status"
}

if [[ $EUID -ne 0 ]]; then
  die 64 'run this helper as root; it reads protected deployment state'
fi
if [[ $(printenv OBSERVABILITY_QUERY_PROVISION_APPROVED 2>/dev/null || true) != true ]]; then
  die 64 'set OBSERVABILITY_QUERY_PROVISION_APPROVED=true after root review'
fi

deploy_dir="$(printenv DEPLOY_DIR 2>/dev/null || printf '%s' '/opt/ai-agent-observability/deploy')"
env_file="$(printenv ENV_FILE 2>/dev/null || printf '%s' "$deploy_dir/.env")"
private_dir="$(printenv PRIVATE_DIR 2>/dev/null || printf '%s' '/run/ai-agent-observability')"
query_key_file="$(printenv QUERY_KEY_FILE 2>/dev/null || printf '%s' '/root/ai-agent-observability/laminar-query-key')"
ch_container="$(printenv CLICKHOUSE_CONTAINER 2>/dev/null || printf '%s' 'ai-agent-observability-laminar-clickhouse')"
pg_container="$(printenv LAMINAR_POSTGRES_CONTAINER 2>/dev/null || printf '%s' 'ai-agent-observability-laminar-postgres')"
operator_key_name='ai-agent-observability operator query'
migrated_ro_user_prefix='lmnr_query_ro_'

for command_name in awk chmod chown cp cut dirname install mktemp mv openssl podman printenv python3 rm stat tail wc; do
  command -v "$command_name" >/dev/null 2>&1 || {
    die 69 "required command is unavailable: $command_name"
  }
done

if [[ ! -f "$env_file" || ! -r "$env_file" || -L "$env_file" ]]; then
  die 69 'deployment .env is unavailable'
fi
env_mode="$(stat -c '%a' "$env_file")"
env_owner="$(stat -c '%u' "$env_file")"
if [[ "$env_mode" != 600 || "$env_owner" != 0 ]]; then
  die 64 'deployment .env must be root-owned mode 0600'
fi

read_dotenv_value() {
  local wanted="$1"
  local required="$2"
  if [[ -z "$required" ]]; then
    required=true
  fi
  python3 - "$env_file" "$wanted" "$required" <<'PY'
import ast
import sys

path, wanted, required = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, separator, value = line.partition("=")
        if separator and name.strip() == wanted:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = ast.literal_eval(value)
            print(value)
            raise SystemExit(0)
if required == "true":
    raise SystemExit(69)
PY
}

project_id="$(read_dotenv_value LAMINAR_PROJECT_ID true)"
postgres_user="$(read_dotenv_value POSTGRES_USER true)"
postgres_password="$(read_dotenv_value POSTGRES_PASSWORD true)"
postgres_db="$(read_dotenv_value POSTGRES_DB true)"
clickhouse_user="$(read_dotenv_value CLICKHOUSE_USER true)"
clickhouse_password="$(read_dotenv_value CLICKHOUSE_PASSWORD true)"
if configured_ro_user="$(read_dotenv_value CLICKHOUSE_RO_USER false 2>/dev/null)"; then
  :
else
  configured_ro_user=''
fi

uuid_pattern='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
if [[ ! "$project_id" =~ $uuid_pattern ]]; then
  die 64 'LAMINAR_PROJECT_ID is not a canonical UUID'
fi
if [[ ! "$postgres_user" =~ ^[A-Za-z0-9_.-]{1,63}$ || ! "$postgres_db" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  die 64 'Laminar PostgreSQL identity is invalid'
fi
if [[ -z "$postgres_password" || -z "$clickhouse_password" ]]; then
  die 69 'existing writer credentials are unavailable'
fi
secret_pattern='^[[:xdigit:]]{64}$'
if [[ ! "$postgres_password" =~ $secret_pattern || ! "$clickhouse_password" =~ $secret_pattern ]]; then
  die 64 'existing writer credentials do not match the generated deployment secret format'
fi
if [[ -n "$configured_ro_user" && ! "$configured_ro_user" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  die 64 'configured ClickHouse read-only user identity is invalid'
fi
if [[ ! "$clickhouse_user" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  die 64 'ClickHouse writer identity is invalid'
fi
if [[ ! "$ch_container" =~ ^[A-Za-z0-9_.-]{1,128}$ || ! "$pg_container" =~ ^[A-Za-z0-9_.-]{1,128}$ ]]; then
  die 64 'container identity is invalid'
fi

if [[ "$(podman inspect --format '{{.State.Running}}' "$ch_container" 2>/dev/null || true)" != true ]]; then
  die 69 'ClickHouse container is not running'
fi
if [[ "$(podman inspect --format '{{.State.Running}}' "$pg_container" 2>/dev/null || true)" != true ]]; then
  die 69 'Laminar PostgreSQL container is not running'
fi

install -d -o root -g root -m 700 "$private_dir"
install -d -o root -g root -m 700 "$(dirname "$query_key_file")"
nonce="$(openssl rand -hex 8)"
migrated_ro_user="${migrated_ro_user_prefix}${nonce}"
if [[ ! "$migrated_ro_user" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  die 69 'generated ClickHouse read-only user identity is invalid'
fi
sql_file="$private_dir/.query-provision.$nonce.sql"
sql_output="$private_dir/.query-provision.$nonce.out"
sql_error="$private_dir/.query-provision.$nonce.err"
db_preflight_sql="$private_dir/.query-preflight.$nonce.sql"
db_preflight_output="$private_dir/.query-preflight.$nonce.out"
db_backup_sql="$private_dir/.query-backup.$nonce.sql"
db_restore_sql="$private_dir/.query-restore.$nonce.sql"
ch_config="$private_dir/.clickhouse-config.$nonce.xml"
ch_ro_config="$private_dir/.clickhouse-ro-config.$nonce.xml"
ch_sql="$private_dir/.clickhouse-query.$nonce.sql"
ch_grant_sql="$private_dir/.clickhouse-grant.$nonce.sql"
ch_output="$private_dir/.clickhouse-query.$nonce.out"
ch_error="$private_dir/.clickhouse-query.$nonce.err"
ch_ownership_evidence="$private_dir/.clickhouse-query-ownership.$nonce"
env_backup="$private_dir/.env.before-query-provision.$nonce"
env_fragment="$private_dir/.env.ro-fragment.$nonce"
new_key_file="$private_dir/.laminar-query-key.$nonce"
pgpass_file="$private_dir/.pgpass.$nonce"
ch_config_path="/run/.sts2-clickhouse-config-$nonce.xml"
ch_ro_config_path="/run/.sts2-clickhouse-ro-config-$nonce.xml"
pgpass_path="/run/.sts2-postgres-pass-$nonce"
key_backup="$private_dir/.laminar-query-key.before-query-provision.$nonce"
key_backup_state="$private_dir/.laminar-query-key.before-query-provision.$nonce.state"
retain_ch_ownership_evidence=false

cleanup() {
  rm -f "$sql_file" "$sql_output" "$sql_error" "$db_preflight_sql" \
    "$db_preflight_output" "$ch_config" "$ch_sql" \
    "$ch_grant_sql" "$ch_output" "$ch_error" "$env_fragment" \
    "$new_key_file" "$pgpass_file"
  if [[ "$retain_ch_ownership_evidence" != true ]]; then
    rm -f "$ch_ro_config" "$ch_ownership_evidence"
  fi
  podman exec "$ch_container" rm -f "$ch_config_path" "$ch_ro_config_path" \
    >/dev/null 2>&1 || true
  podman exec "$pg_container" rm -f "$pgpass_path" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -e "$env_backup" || -e "$key_backup" || -e "$key_backup_state" \
  || -e "$ch_ownership_evidence" || -e "$ch_ro_config" ]]; then
  die 69 'private backup path collision'
fi

# The legacy image used CLICKHOUSE_RO_USER=lmnr, which aliases the writer.
# Do not reject that value before contacting the live ClickHouse instance.
# After the live preflight, migrate it to a distinct reserved account.
if [[ -z "$configured_ro_user" || "$configured_ro_user" == "$clickhouse_user" ]]; then
  ro_user="$migrated_ro_user"
  legacy_migration=true
else
  ro_user="$configured_ro_user"
  legacy_migration=false
fi
if [[ "$ro_user" == "$clickhouse_user" || ! "$ro_user" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  die 64 'ClickHouse read-only user must be distinct from the writer user'
fi

cat >"$ch_config" <<XML
<config><host>127.0.0.1</host><user>$clickhouse_user</user><password>$clickhouse_password</password></config>
XML
chmod 600 "$ch_config"
if ! podman exec -i "$ch_container" sh -c 'umask 077; cat > "$1"' sh "$ch_config_path" \
  <"$ch_config" >/dev/null 2>"$ch_error"; then
  die 69 'could not install protected ClickHouse writer config'
fi

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

# Live preflight first proves the writer is present, discovers the legacy
# account situation, and only then admits the migration target.
if ! run_clickhouse_query "$ch_config_path" \
  "SELECT name FROM system.users WHERE name = '$clickhouse_user' FORMAT TSV"; then
  die 1 'ClickHouse user preflight failed'
fi
if ! grep -Fxq "$clickhouse_user" "$ch_output"; then
  die 64 'configured ClickHouse writer user is absent from the live server'
fi
if [[ "$legacy_migration" == true ]]; then
  legacy_ro_display="$configured_ro_user"
  if [[ -z "$legacy_ro_display" ]]; then
    legacy_ro_display='<unset>'
  fi
  printf 'legacy_clickhouse_ro_user=%s migration_target=%s\n' \
    "$legacy_ro_display" "$ro_user"
fi
if ! run_clickhouse_query "$ch_config_path" \
  "SELECT name FROM system.users WHERE name = '$ro_user' FORMAT TSV"; then
  die 1 'ClickHouse read-only user collision preflight failed'
fi
if grep -Fxq "$ro_user" "$ch_output"; then
  die 64 'configured ClickHouse read-only user already exists; refusing an account collision'
fi

if ! run_clickhouse_query "$ch_config_path" \
  "SELECT name, engine FROM system.tables WHERE database='default' AND name IN ('spans','spans_v0') ORDER BY name FORMAT TSV"; then
  die 1 'ClickHouse schema preflight failed'
fi
python3 - "$ch_output" <<'PY'
import pathlib
import sys

rows = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    fields = line.split("\t")
    if len(fields) == 2:
        rows[fields[0]] = fields[1]
if rows.get("spans") not in {"MergeTree", "ReplacingMergeTree"}:
    raise SystemExit("default.spans is not the expected deployed table engine")
if rows.get("spans_v0") != "View":
    raise SystemExit("default.spans_v0 is not the expected deployed view engine")
PY
if ! run_clickhouse_query "$ch_config_path" \
  "DESCRIBE TABLE default.spans FORMAT TSV"; then
  die 1 'ClickHouse spans schema preflight failed'
fi
python3 - "$ch_output" <<'PY'
import pathlib
import sys

names = {line.split("\t", 1)[0] for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line}
required = {"span_id", "trace_id", "status", "start_time", "end_time", "attributes"}
if not required <= names:
    raise SystemExit("default.spans is missing a required correlation column")
PY
printf '%s\n' 'clickhouse_schema=validated deployed_spans=table deployed_spans_v0=view'

# Install the PostgreSQL client password through a protected container file.
# The file is temporary and is removed by cleanup, never passed as an argv
# value. Its presence is part of the preflight boundary, before backups.
printf '*:*:*:%s:%s\n' "$postgres_user" "$postgres_password" >"$pgpass_file"
chmod 600 "$pgpass_file"
if ! podman exec -i "$pg_container" sh -c 'umask 077; cat > "$1"' sh "$pgpass_path" \
  <"$pgpass_file" >/dev/null 2>"$sql_error"; then
  die 69 'could not install protected PostgreSQL client credentials'
fi

run_psql_file() {
  local input_file="$1"
  podman exec -i "$pg_container" env PGPASSFILE="$pgpass_path" \
    psql --no-psqlrc --no-password --quiet --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 \
    --host=127.0.0.1 --port=5432 --username="$postgres_user" \
    --dbname="$postgres_db" --file=- <"$input_file" \
    >"$sql_output" 2>"$sql_error"
}

cat >"$db_preflight_sql" <<SQL
SELECT 'project=' || count(*) FROM projects WHERE id = '$project_id'::uuid;
SELECT 'collector=' || count(*) FROM project_api_keys
 WHERE project_id = '$project_id'::uuid AND is_ingest_only = true;
SELECT 'operator=' || count(*) FROM project_api_keys
 WHERE project_id = '$project_id'::uuid AND name = '$operator_key_name';
SQL
chmod 600 "$db_preflight_sql"
if ! run_psql_file "$db_preflight_sql"; then
  die 1 'Laminar PostgreSQL preflight failed'
fi
cp "$sql_output" "$db_preflight_output"
chmod 600 "$db_preflight_output"
python3 - "$db_preflight_output" <<'PY'
import pathlib
import sys

values = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    name, separator, value = line.partition("=")
    if separator:
        values[name] = int(value)
if values.get("project") != 1:
    raise SystemExit("configured Laminar project does not exist exactly once")
if values.get("collector", 0) < 1:
    raise SystemExit("Collector ingest-only key row is missing")
if values.get("operator", 0) > 1:
    raise SystemExit("operator query key has duplicate rows")
PY

# Capture a SQL-safe restoration statement for the existing operator row
# before replacing it. An absent row is recorded as an empty backup.
cat >"$db_backup_sql" <<SQL
SELECT format(
  'INSERT INTO project_api_keys (id, name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value, created_at) VALUES (%L, %L, %L, %L, %L, %L, %L, %L, %L, %L);',
  id, name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value, created_at)
FROM project_api_keys
WHERE project_id = '$project_id'::uuid
  AND name = '$operator_key_name';
SQL
chmod 600 "$db_backup_sql"
if ! run_psql_file "$db_backup_sql"; then
  die 1 'could not capture the existing operator key row'
fi
cp "$sql_output" "$db_backup_sql"
chmod 600 "$db_backup_sql"
operator_backup_lines="$(wc -l <"$db_backup_sql")"
if [[ "$operator_backup_lines" -gt 1 ]]; then
  die 69 'operator key backup returned duplicate rows'
fi
if [[ "$operator_backup_lines" -eq 1 && ! -s "$db_backup_sql" ]]; then
  die 69 'operator key backup was empty unexpectedly'
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
clickhouse_ro_password="$(openssl rand -hex 32)"
query_key_length="$(printf '%s' "$query_key" | wc -c)"
query_hash_length="$(printf '%s' "$query_key_hash" | wc -c)"
ro_password_length="$(printf '%s' "$clickhouse_ro_password" | wc -c)"
if [[ "$query_key_length" -ne 64 || "$query_hash_length" -ne 64 || "$ro_password_length" -ne 64 ]]; then
  die 69 'generated credential did not meet the required bound'
fi
printf '%s\n' "$query_key" >"$new_key_file"
chmod 600 "$new_key_file"

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
key_mutation_attempted=false
env_mutation_attempted=false

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
      {
        cat <<SQL
BEGIN;
DELETE FROM project_api_keys
 WHERE project_id = '$project_id'::uuid
   AND name = '$operator_key_name';
SQL
        if [[ -s "$db_backup_sql" ]]; then
          cat "$db_backup_sql"
        fi
        cat <<SQL
COMMIT;
SQL
      } >"$db_restore_sql"
      chmod 600 "$db_restore_sql"
      if ! run_psql_file "$db_restore_sql"; then
        rollback_failed=true
        printf '%s\n' 'rollback failed while restoring the prior PostgreSQL operator key' >&2
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
    printf 'rollback_env_backup=%s\n' "$env_backup" >&2
    printf 'rollback_key_backup=%s\n' "$key_backup" >&2
    printf 'rollback_db_backup=%s\n' "$db_backup_sql" >&2
    if [[ "$rollback_failed" == true ]]; then
      printf '%s\n' 'automatic compensation was incomplete; keep the backups and reconcile by exact project/container identity' >&2
      cleanup
      exit 70
    fi
  fi
  cleanup
  exit "$status"
}
trap rollback EXIT

# Install the protected key before the database commit. This ensures that a
# process interruption cannot leave a committed database hash with no durable
# copy of the corresponding secret.
key_mutation_attempted=true
mv -f "$new_key_file" "$query_key_file"
chmod 600 "$query_key_file"
chown root:root "$query_key_file"

# The query-key transaction preserves the Collector row and replaces only the
# scoped operator row. It has no CREATE USER side effects.
cat >"$sql_file" <<SQL
BEGIN;
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM projects
    WHERE id = '$project_id'::uuid
  ) THEN
    RAISE EXCEPTION 'configured Laminar project does not exist';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM project_api_keys
    WHERE project_id = '$project_id'::uuid
      AND is_ingest_only = true
  ) THEN
    RAISE EXCEPTION 'Collector ingest-only key row is missing';
  END IF;
END
\$\$;
DELETE FROM project_api_keys
WHERE project_id = '$project_id'::uuid
  AND name = '$operator_key_name';
INSERT INTO project_api_keys
  (name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value)
VALUES
  ('$operator_key_name', '$project_id'::uuid, '$query_shorthand',
   '$query_key_hash', false, NULL, NULL, '');
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
chmod 600 "$sql_file"

pg_mutation_attempted=true
if ! run_psql_file "$sql_file"; then
  die 1 'Laminar operator key transaction failed; raw database output remains root-private'
fi
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
