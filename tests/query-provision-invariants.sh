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
  'readonly = 1' \
  'read-only user must be distinct from the writer user' \
  'GRANT SELECT ON default.spans' \
  'GRANT SELECT ON default.spans_v0'; do
  grep -Fq -- "$required" "$script"
done

grep -Fq 'CLICKHOUSE_RO_USER=lmnr_query_ro' "$repo_root/deploy/.env.example"
grep -Fq 'clickhouse_ro_password=' "$repo_root/deploy/init.sh"
grep -Fq 'CLICKHOUSE_RO_USER: ${CLICKHOUSE_RO_USER}' "$repo_root/deploy/compose.yaml"
grep -Fq 'CLICKHOUSE_RO_PASSWORD: ${CLICKHOUSE_RO_PASSWORD}' "$repo_root/deploy/compose.yaml"
printf '%s\n' 'Query provisioning and protected credential invariants passed.'
