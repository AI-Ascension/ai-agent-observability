#!/bin/sh
# Authenticated ClickHouse readiness using the identity supplied to the
# container. The query is constant and read-only; no result is printed.
set -eu

: "${CLICKHOUSE_USER:?CLICKHOUSE_USER is required}"
: "${CLICKHOUSE_PASSWORD:?CLICKHOUSE_PASSWORD is required}"

host=${CLICKHOUSE_HOST:-127.0.0.1}
port=${CLICKHOUSE_PORT:-9000}
user=${CLICKHOUSE_HEALTH_USER:-$CLICKHOUSE_USER}
password=${CLICKHOUSE_HEALTH_PASSWORD:-$CLICKHOUSE_PASSWORD}
database=${CLICKHOUSE_DATABASE:-default}
: "${user:?CLICKHOUSE_HEALTH_USER must not be empty}"
: "${password:?CLICKHOUSE_HEALTH_PASSWORD must not be empty}"
case "$port" in
  ''|*[!0-9]*) exit 1 ;;
esac

probe_timeout=3s
probe_max_output_bytes=4096
probe_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/clickhouse-readiness.XXXXXX") || exit 1

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

# clickhouse-client accepts CLICKHOUSE_PASSWORD from its child environment;
# keeping the value out of argv avoids exposing it through process inspection.
CLICKHOUSE_PASSWORD="$password" run_bounded "$probe_tmp_dir/query" clickhouse-client \
  --host="$host" --port="$port" \
  --user="$user" --database="$database" \
  --query='SELECT 1' --format=TabSeparatedRaw || exit 1

result=$(cat "$probe_tmp_dir/query") || exit 1

[ "$result" = 1 ]
