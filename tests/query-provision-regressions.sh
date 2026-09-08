#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/deploy/laminar/provision-query-readonly.sh"
test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT

for mode in stopped error; do
  case_root="$test_root/$mode"
  mkdir -p "$case_root/bin" "$case_root/deploy" "$case_root/private"
  cp "$repo_root/tests/fixtures/query-provision-podman" "$case_root/bin/podman"
  chmod +x "$case_root/bin/podman"

  cat >"$case_root/deploy/.env" <<'EOF'
LAMINAR_PROJECT_ID=01234567-89ab-4def-8123-456789abcdef
POSTGRES_USER=laminar
POSTGRES_PASSWORD=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
POSTGRES_DB=laminar
CLICKHOUSE_USER=lmnr
CLICKHOUSE_PASSWORD=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
CLICKHOUSE_RO_USER=lmnr_query_ro
EOF
  chmod 600 "$case_root/deploy/.env"
  printf '%s\n' 'existing query key marker' >"$case_root/query-key"
  chmod 600 "$case_root/query-key"
  printf '%s\n' 'existing private state marker' >"$case_root/private/state"
  chmod 600 "$case_root/private/state"
  env_hash="$(sha256sum "$case_root/deploy/.env")"
  key_hash="$(sha256sum "$case_root/query-key")"
  private_hash="$(sha256sum "$case_root/private/state")"

  status=0
  PATH="$case_root/bin:$PATH" \
    FAKE_PODMAN_LOG="$case_root/podman.log" \
    FAKE_PODMAN_MODE="$mode" \
    OBSERVABILITY_QUERY_PROVISION_APPROVED=true \
    DEPLOY_DIR="$case_root/deploy" \
    ENV_FILE="$case_root/deploy/.env" \
    PRIVATE_DIR="$case_root/private" \
    QUERY_KEY_FILE="$case_root/query-key" \
    CLICKHOUSE_CONTAINER=synthetic-clickhouse \
    LAMINAR_POSTGRES_CONTAINER=synthetic-postgres \
    bash "$script" >"$case_root/output" 2>&1 || status=$?
  if (( EUID == 0 )); then
    [[ $status == 69 ]]
    grep -Fq 'ClickHouse container is not running' "$case_root/output"
  else
    [[ $status == 64 ]]
    grep -Fq 'run this helper as root' "$case_root/output"
  fi
  [[ "$(sha256sum "$case_root/deploy/.env")" == "$env_hash" ]]
  [[ "$(sha256sum "$case_root/query-key")" == "$key_hash" ]]
  [[ "$(sha256sum "$case_root/private/state")" == "$private_hash" ]]
  [[ "$(find "$case_root/private" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)" == state ]]
  if (( EUID == 0 )); then
    [[ $(wc -l <"$case_root/podman.log") == 1 ]]
    grep -Fq 'inspect --format {{.State.Running}} synthetic-clickhouse' "$case_root/podman.log"
    if grep -Eq 'exec|psql|clickhouse-client' "$case_root/podman.log"; then
      printf 'Synthetic preflight reached a mutation/query operation in %s mode.\n' "$mode" >&2
      exit 1
    fi
  else
    [[ ! -e "$case_root/podman.log" ]]
  fi
done

if (( EUID == 0 )); then
  printf '%s\n' 'Query provisioning stopped/error preflights preserve existing synthetic state (no service or data mutation).'
else
  printf '%s\n' 'Query provisioning root guard preserves existing synthetic state (preflight process path requires root).'
fi
