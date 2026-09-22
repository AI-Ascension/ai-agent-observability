#!/usr/bin/env bash
# PostgreSQL probe — protected pgpass-backed psql file runner
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the shared globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

run_psql_file() {
  local input_file="$1"
  podman exec -i "$pg_container" env PGPASSFILE="$pgpass_path" \
    psql --no-psqlrc --no-password --quiet --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 \
    --host=127.0.0.1 --port=5432 --username="$postgres_user" \
    --dbname="$postgres_db" --file=- <"$input_file" \
    >"$sql_output" 2>"$sql_error"
}
