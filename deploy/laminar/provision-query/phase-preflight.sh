#!/usr/bin/env bash
# Preflight phase — env identity, live ClickHouse and PostgreSQL reads before backups
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the ordering globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

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
db_backup_meta_sql="$private_dir/.query-backup-meta-input.$nonce.sql"
db_backup_meta="$private_dir/.query-backup-meta.$nonce"
db_reconcile_sql="$private_dir/.query-reconcile.$nonce.sql"
db_restore_sql="$private_dir/.query-restore.$nonce.sql"
candidate_key_evidence="$private_dir/.laminar-query-key.candidate.$nonce"
pg_reconciliation_evidence="$private_dir/.postgres-query-reconciliation.$nonce"
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
retain_pg_reconciliation_evidence=false

trap cleanup EXIT

if [[ -e "$env_backup" || -e "$key_backup" || -e "$key_backup_state" \
  || -e "$ch_ownership_evidence" || -e "$ch_ro_config" \
  || -e "$candidate_key_evidence" || -e "$pg_reconciliation_evidence" ]]; then
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
