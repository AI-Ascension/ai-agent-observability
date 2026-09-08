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
reader_pid=

# Stop the FIFO reader and the native client together. The reader is separate
# from the client group, while the timeout/client group may contain children
# that ignore TERM. Send TERM first, then KILL after a bounded grace period,
# and reap every process before returning the probe's failure status.
cleanup_processes() {
  active=0
  if [ -n "${reader_pid:-}" ]; then
    kill -TERM "$reader_pid" 2>/dev/null || true
    active=1
  fi
  if [ -n "${runner_pid:-}" ]; then
    kill -TERM -"$runner_pid" 2>/dev/null || true
    active=1
  fi
  if [ "$active" -eq 1 ]; then
    sleep 1
    if [ -n "${reader_pid:-}" ]; then
      kill -KILL "$reader_pid" 2>/dev/null || true
    fi
    if [ -n "${runner_pid:-}" ]; then
      kill -KILL -"$runner_pid" 2>/dev/null || true
    fi
    if [ -n "${reader_pid:-}" ]; then
      wait "$reader_pid" 2>/dev/null || true
      reader_pid=
    fi
    if [ -n "${runner_pid:-}" ]; then
      wait "$runner_pid" 2>/dev/null || true
      runner_pid=
    fi
  fi
}

# A client can exit successfully while a descendant still has the FIFO open.
# Once the timeout/client status is known, close that whole process group
# before waiting for the reader so a successful direct exit cannot leak the
# reader indefinitely.
stop_runner_group() {
  pid=$1
  [ -n "$pid" ] || return 0
  kill -TERM -"$pid" 2>/dev/null || true
  kill -KILL -"$pid" 2>/dev/null || true
}

wait_reader_bounded() {
  polls=0
  while kill -0 "$reader_pid" 2>/dev/null; do
    if [ "$polls" -ge 5 ]; then
      kill -TERM "$reader_pid" 2>/dev/null || true
      kill -KILL "$reader_pid" 2>/dev/null || true
      break
    fi
    sleep 0.05
    polls=$((polls + 1))
  done
  reader_status=0
  wait "$reader_pid" 2>/dev/null || reader_status=$?
  reader_pid=
}

cleanup_exit() {
  status=$?
  trap - EXIT
  trap ':' HUP INT TERM
  cleanup_processes
  rm -rf "$probe_tmp_dir"
  exit "$status"
}

cleanup_signal() {
  status=$1
  trap - EXIT
  trap ':' HUP INT TERM
  cleanup_processes
  rm -rf "$probe_tmp_dir"
  exit "$status"
}

trap cleanup_exit EXIT
trap 'cleanup_signal 129' HUP
trap 'cleanup_signal 130' INT
trap 'cleanup_signal 143' TERM

run_bounded() {
  output_file=$1
  shift
  fifo="$output_file.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" || return 1
  timeout --signal=TERM --kill-after=1s "$probe_timeout" "$@" \
    >"$fifo" 2>/dev/null &
  runner_pid=$!
  dd if="$fifo" bs=1 count=$((probe_max_output_bytes + 1)) \
    >"$output_file" 2>/dev/null &
  reader_pid=$!
  status=0
  wait "$runner_pid" 2>/dev/null || status=$?
  stop_runner_group "$runner_pid"
  runner_pid=
  wait_reader_bounded
  rm -f "$fifo"
  [ "$status" -eq 0 ] || return 1
  [ "$reader_status" -eq 0 ] || return 1
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
