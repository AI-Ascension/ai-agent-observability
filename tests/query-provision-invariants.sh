#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/deploy/laminar/provision-query-readonly.sh"
bash -n "$script"

if grep -Eq -- '--password(=|[[:space:]])|sudoedit|docker exec|(^|[[:space:]])source[[:space:]]+.*\.env' "$script"; then
  printf '%s\n' 'query provisioning exposes a credential through an unsafe command path' >&2
  exit 1
fi
for required in \
  'PGPASSFILE=' \
  '--config-file' \
  'openssl dgst -sha3-256' \
  'is_ingest_only = true' \
  'is_ingest_only, user_id, expires_at, value' \
  'id, name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value, created_at' \
  'readonly = 1' \
  'read-only user must be distinct from the writer user' \
  'GRANT SELECT ON default.spans' \
  'GRANT SELECT ON default.spans_v0' \
  'legacy_clickhouse_ro_user=' \
  'migration_target=' \
  'deterministic compensation' \
  'DROP USER IF EXISTS' \
  'ch_user_created=false' \
  'migrated_ro_user_prefix=' \
  'ch_user_id=' \
  'drop_owned_clickhouse_user' \
  'retain_ch_ownership_evidence=true' \
  'not an atomic ClickHouse primitive' \
  'refusing to drop a ClickHouse user after an ambiguous CREATE failure' \
  'protected key before the database commit' \
  'no-align --tuples-only' \
  'BEGIN ISOLATION LEVEL REPEATABLE READ' \
  'backup_sql_hex=' \
  'operator_insert_id=' \
  'candidate=match' \
  'pg_mutation_committed=unknown' \
  'candidate_key_evidence=' \
  'retain_pg_reconciliation_artifacts' \
  'commit outcome remains unknown' \
  'commit reconciliation' \
  'operator key changed since its exact backup'; do
  grep -Fq -- "$required" "$script"
done

if grep -Fq -- 'CREATE USER IF NOT EXISTS' "$script"; then
  printf '%s\n' 'query provisioning must refuse an existing account or reset it exactly' >&2
  exit 1
fi

grep -Fq 'CLICKHOUSE_RO_USER=lmnr_query_ro' "$repo_root/deploy/.env.example"
grep -Fq 'clickhouse_ro_password=' "$repo_root/deploy/init.sh"
grep -Fq 'CLICKHOUSE_RO_USER: ${CLICKHOUSE_RO_USER}' "$repo_root/deploy/compose.yaml"
grep -Fq 'CLICKHOUSE_RO_PASSWORD: ${CLICKHOUSE_RO_PASSWORD}' "$repo_root/deploy/compose.yaml"
printf '%s\n' 'Query provisioning and protected credential invariants passed.'
