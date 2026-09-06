#!/usr/bin/env bash
set -euo pipefail

# Provision the separate Laminar operator query key and ClickHouse read-only
# account without placing a secret in process arguments, shell history, or
# evidence. This helper is deliberately root-only and does not restart the
# Compose project. Run the reviewed project-scoped recreate separately after
# checking the staged .env diff.

if [[ $EUID -ne 0 ]]; then
  printf '%s\n' 'run this helper as root; it reads protected deployment state' >&2
  exit 64
fi
if [[ ${OBSERVABILITY_QUERY_PROVISION_APPROVED:-false} != true ]]; then
  printf '%s\n' 'set OBSERVABILITY_QUERY_PROVISION_APPROVED=true after root review' >&2
  exit 64
fi

readonly deploy_dir="${DEPLOY_DIR:-/opt/ai-agent-observability/deploy}"
readonly env_file="${ENV_FILE:-$deploy_dir/.env}"
readonly private_dir="${PRIVATE_DIR:-/run/ai-agent-observability}"
readonly query_key_file="${QUERY_KEY_FILE:-/root/ai-agent-observability/laminar-query-key}"
readonly ch_container="${CLICKHOUSE_CONTAINER:-ai-agent-observability-laminar-clickhouse}"
readonly pg_container="${LAMINAR_POSTGRES_CONTAINER:-ai-agent-observability-laminar-postgres}"
readonly operator_key_name='ai-agent-observability operator query'

for command_name in chmod cp install mktemp mv openssl podman python3 rm stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 69
  }
done

if [[ ! -f "$env_file" || ! -r "$env_file" ]]; then
  printf '%s\n' 'deployment .env is unavailable' >&2
  exit 69
fi
env_mode="$(stat -c '%a' "$env_file")"
env_owner="$(stat -c '%u' "$env_file")"
if [[ "$env_mode" != 600 || "$env_owner" != 0 ]]; then
  printf '%s\n' 'deployment .env must be root-owned mode 0600' >&2
  exit 64
fi

read_dotenv_value() {
  local key="$1"
  python3 - "$env_file" "$key" <<'PY'
import ast
import sys

path, wanted = sys.argv[1:]
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
raise SystemExit(69)
PY
}

readonly project_id="$(read_dotenv_value LAMINAR_PROJECT_ID)"
readonly postgres_user="$(read_dotenv_value POSTGRES_USER)"
readonly postgres_password="$(read_dotenv_value POSTGRES_PASSWORD)"
readonly postgres_db="$(read_dotenv_value POSTGRES_DB)"
readonly clickhouse_user="$(read_dotenv_value CLICKHOUSE_USER)"
readonly clickhouse_password="$(read_dotenv_value CLICKHOUSE_PASSWORD)"
readonly ro_user="$(read_dotenv_value CLICKHOUSE_RO_USER)"

uuid_pattern='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
if [[ ! "$project_id" =~ $uuid_pattern ]]; then
  printf '%s\n' 'LAMINAR_PROJECT_ID is not a canonical UUID' >&2
  exit 64
fi
if [[ ! "$postgres_user" =~ ^[A-Za-z0-9_.-]{1,63}$ || ! "$postgres_db" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  printf '%s\n' 'Laminar PostgreSQL identity is invalid' >&2
  exit 64
fi
if [[ -z "$postgres_password" || -z "$clickhouse_password" ]]; then
  printf '%s\n' 'existing writer credentials are unavailable' >&2
  exit 69
fi
secret_pattern='^[[:xdigit:]]{64}$'
if [[ ! "$postgres_password" =~ $secret_pattern || ! "$clickhouse_password" =~ $secret_pattern ]]; then
  printf '%s\n' 'existing writer credentials do not match the generated deployment secret format' >&2
  exit 64
fi
if [[ ! "$clickhouse_user" =~ ^[A-Za-z0-9_.-]{1,63}$ || ! "$ro_user" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]; then
  printf '%s\n' 'ClickHouse user identity is invalid' >&2
  exit 64
fi
if [[ "$clickhouse_user" == "$ro_user" ]]; then
  printf '%s\n' 'ClickHouse read-only user must be distinct from the writer user' >&2
  exit 64
fi
if [[ ! "$ch_container" =~ ^[A-Za-z0-9_.-]{1,128}$ || ! "$pg_container" =~ ^[A-Za-z0-9_.-]{1,128}$ ]]; then
  printf '%s\n' 'container identity is invalid' >&2
  exit 64
fi

if [[ "$(podman inspect --format '{{.State.Running}}' "$ch_container" 2>/dev/null || true)" != true ]]; then
  printf '%s\n' 'ClickHouse container is not running' >&2
  exit 69
fi
if [[ "$(podman inspect --format '{{.State.Running}}' "$pg_container" 2>/dev/null || true)" != true ]]; then
  printf '%s\n' 'Laminar PostgreSQL container is not running' >&2
  exit 69
fi

install -d -o root -g root -m 700 "$private_dir"
install -d -o root -g root -m 700 "$(dirname "$query_key_file")"
nonce="$(openssl rand -hex 8)"
readonly sql_file="$private_dir/.query-provision.$nonce.sql"
readonly sql_output="$private_dir/.query-provision.$nonce.out"
readonly sql_error="$private_dir/.query-provision.$nonce.err"
readonly ch_config="$private_dir/.clickhouse-config.$nonce.xml"
readonly ch_ro_config="$private_dir/.clickhouse-ro-config.$nonce.xml"
readonly ch_sql="$private_dir/.clickhouse-query.$nonce.sql"
readonly ch_output="$private_dir/.clickhouse-query.$nonce.out"
readonly ch_error="$private_dir/.clickhouse-query.$nonce.err"
readonly env_backup="$private_dir/.env.before-query-provision.$nonce"
readonly env_fragment="$private_dir/.env.ro-fragment.$nonce"
readonly new_key_file="$private_dir/.laminar-query-key.$nonce"
readonly pgpass_file="$private_dir/.pgpass.$nonce"
readonly ch_config_path="/run/.sts2-clickhouse-config-$nonce.xml"
readonly ch_ro_config_path="/run/.sts2-clickhouse-ro-config-$nonce.xml"
readonly pgpass_path="/run/.sts2-postgres-pass-$nonce"

cleanup() {
  rm -f "$sql_file" "$sql_output" "$sql_error" "$ch_config" "$ch_ro_config" \
    "$ch_sql" "$ch_output" "$ch_error" "$env_fragment" "$new_key_file" \
    "$pgpass_file"
  podman exec "$ch_container" rm -f "$ch_config_path" "$ch_ro_config_path" \
    >/dev/null 2>&1 || true
  podman exec "$pg_container" rm -f "$pgpass_path" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -e "$env_backup" ]]; then
  printf '%s\n' 'private backup path collision' >&2
  exit 69
fi
cp -p "$env_file" "$env_backup"
chmod 600 "$env_backup"

query_key="$(openssl rand -hex 32)"
query_key_hash="$(printf '%s' "$query_key" | openssl dgst -sha3-256 -r | awk '{print $1}')"
query_shorthand="$(printf '%s...%s' "${query_key:0:4}" "${query_key: -4}")"
clickhouse_ro_password="$(openssl rand -hex 32)"
if [[ ${#query_key} -ne 64 || ${#query_key_hash} -ne 64 || ${#clickhouse_ro_password} -ne 64 ]]; then
  printf '%s\n' 'generated credential did not meet the required bound' >&2
  exit 69
fi

cat >"$ch_config" <<XML
<config><host>127.0.0.1</host><user>$clickhouse_user</user><password>$clickhouse_password</password></config>
XML
chmod 600 "$ch_config"
if ! podman exec -i "$ch_container" sh -c 'umask 077; cat > "$1"' sh "$ch_config_path" \
  <"$ch_config" >/dev/null 2>"$ch_error"; then
  printf '%s\n' 'could not install protected ClickHouse writer config' >&2
  exit 69
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

if ! run_clickhouse_query "$ch_config_path" \
  "SELECT name, engine FROM system.tables WHERE database='default' AND name IN ('spans','spans_v0') ORDER BY name FORMAT TSV"; then
  printf '%s\n' 'ClickHouse schema preflight failed' >&2
  exit 1
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
  printf '%s\n' 'ClickHouse spans schema preflight failed' >&2
  exit 1
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


cat >"$ch_sql" <<SQL
CREATE USER IF NOT EXISTS \`$ro_user\`
  IDENTIFIED WITH sha256_password BY '$clickhouse_ro_password';
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
chmod 600 "$ch_sql"
if ! podman exec -i "$ch_container" clickhouse-client \
  --config-file "$ch_config_path" --multiquery <"$ch_sql" \
  >"$ch_output" 2>"$ch_error"; then
  printf '%s\n' 'ClickHouse read-only user transaction failed; raw output remains root-private' >&2
  exit 1
fi

cat >"$ch_ro_config" <<XML
<config><host>127.0.0.1</host><user>$ro_user</user><password>$clickhouse_ro_password</password></config>
XML
chmod 600 "$ch_ro_config"
if ! podman exec -i "$ch_container" sh -c 'umask 077; cat > "$1"' sh "$ch_ro_config_path" \
  <"$ch_ro_config" >/dev/null 2>"$ch_error"; then
  printf '%s\n' 'could not install protected ClickHouse read-only config' >&2
  exit 69
fi
if ! run_clickhouse_query "$ch_config_path" \
  "SHOW GRANTS FOR \`$ro_user\` FORMAT TSV"; then
  printf '%s\n' 'could not verify ClickHouse read-only grants' >&2
  exit 1
fi
python3 - "$ch_output" "$ro_user" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
user = sys.argv[2]
if "SELECT" not in text or "default.spans" not in text or "default.spans_v0" not in text:
    raise SystemExit("read-only grants did not include both exposed span objects")
if user not in text:
    raise SystemExit("read-only grants named an unexpected user")
PY
if ! run_clickhouse_query "$ch_ro_config_path" \
  "SELECT 1 FROM default.spans LIMIT 1 FORMAT TSV"; then
  printf '%s\n' 'read-only spans query was denied' >&2
  exit 1
fi
if ! run_clickhouse_query "$ch_ro_config_path" \
  "SELECT 1 FROM default.spans_v0 LIMIT 1 FORMAT TSV"; then
  printf '%s\n' 'read-only spans_v0 query was denied' >&2
  exit 1
fi
printf '%s\n' 'clickhouse_readonly=verified objects=default.spans,default.spans_v0'

# The query key transaction is scoped to the existing project. It preserves
# the Collector row and atomically replaces only this operator row.
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

printf '*:*:*:%s:%s\n' "$postgres_user" "$postgres_password" >"$pgpass_file"
chmod 600 "$pgpass_file"
if ! podman exec -i "$pg_container" sh -c 'umask 077; cat > "$1"' sh "$pgpass_path" \
  <"$pgpass_file" >/dev/null 2>"$sql_error"; then
  printf '%s\n' 'could not install protected PostgreSQL client credentials' >&2
  exit 69
fi
if ! podman exec -i "$pg_container" env PGPASSFILE="$pgpass_path" \
  psql --no-psqlrc --no-password --quiet --set=ON_ERROR_STOP=1 \
  --host=127.0.0.1 --port=5432 --username="$postgres_user" \
  --dbname="$postgres_db" --file=- <"$sql_file" \
  >"$sql_output" 2>"$sql_error"; then
  printf '%s\n' 'Laminar operator key transaction failed; raw database output remains root-private' >&2
  exit 1
fi
printf '%s\n' 'operator query key transaction=committed collector_key=preserved'


# Update only the two protected Compose values. The prior file is retained in
# PRIVATE_DIR for rollback; this operation does not render interpolated config.
printf 'CLICKHOUSE_RO_USER=%s\nCLICKHOUSE_RO_PASSWORD=%s\n' \
  "$ro_user" "$clickhouse_ro_password" >"$env_fragment"
chmod 600 "$env_fragment"
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

printf '%s\n' "$query_key" >"$new_key_file"
chmod 600 "$new_key_file"
mv -f "$new_key_file" "$query_key_file"
printf 'query_key_file=installed mode=0600 user=%s clickhouse_env=updated\n' "$query_key_file"
printf 'container_identity=%s image_id=%s\n' \
  "$ch_container" "$(podman inspect --format '{{.Image}}' "$ch_container")"
printf 'rollback_env_backup=%s\n' "$env_backup"
printf '%s\n' 'No service restart was performed; recreate only the reviewed app-server/frontend services after inspecting the protected .env diff.'
