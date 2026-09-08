#!/bin/sh
# Native PostgreSQL liveness plus an authenticated, read-only SELECT 1.
# Credentials stay in the container environment and are never printed.
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"

host=${PGHOST:-127.0.0.1}
port=${PGPORT:-5432}
case "$port" in
  ''|*[!0-9]*) exit 1 ;;
esac

# Keep each native client bounded even when the healthcheck runner itself is
# misconfigured. GNU timeout starts the client in its own process group; its
# TERM/KILL sequence therefore also cleans up descendants. A bounded FIFO
# reader prevents an unhealthy client from making command substitution retain
# unbounded output in memory.
probe_timeout=3s
probe_max_output_bytes=4096
probe_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/postgres-readiness.XXXXXX") || exit 1

runner_pid=
cleanup() {
  status=$?
  if [ -n "${runner_pid:-}" ]; then
    kill -TERM -- "-$runner_pid" 2>/dev/null || kill -TERM "$runner_pid" 2>/dev/null || true
  fi
  rm -rf "$probe_tmp_dir"
  trap - EXIT HUP INT TERM
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

run_bounded() {
  output_file=$1
  shift
  fifo="$output_file.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" || return 1
  timeout --signal=TERM --kill-after=1s "$probe_timeout" "$@" \
    >"$fifo" 2>/dev/null &
  runner_pid=$!
  if ! dd if="$fifo" bs=1 count=$((probe_max_output_bytes + 1)) \
    >"$output_file" 2>/dev/null; then
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    runner_pid=
    rm -f "$fifo"
    return 1
  fi
  status=0
  wait "$runner_pid" 2>/dev/null || status=$?
  runner_pid=
  rm -f "$fifo"
  [ "$status" -eq 0 ] || return 1
  output_bytes=$(wc -c <"$output_file") || return 1
  case "$output_bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$output_bytes" -le "$probe_max_output_bytes" ]
}

# Keep server liveness distinct from authentication/query readiness. A server
# can answer pg_isready while the application identity is rejected.
run_bounded "$probe_tmp_dir/liveness" pg_isready -q -h "$host" -p "$port" \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1

PGPASSWORD="$POSTGRES_PASSWORD" run_bounded "$probe_tmp_dir/query" psql \
  --no-psqlrc --no-password --quiet --no-align --tuples-only \
  --set=ON_ERROR_STOP=1 \
  --host="$host" --port="$port" \
  --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" \
  --command='SELECT 1' || exit 1

result=$(cat "$probe_tmp_dir/query") || exit 1

[ "$result" = 1 ]
