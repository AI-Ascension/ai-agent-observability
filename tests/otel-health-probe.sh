#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
server_pid=""
trap 'if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi; rm -r -- "$test_root"' EXIT

if ! command -v gcc >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'gcc and python3 are required for the Collector probe fixture test.' >&2
  exit 1
fi

gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -static -s \
  -o "$test_root/otel-health-probe" "$repo_root/deploy/otel-health-probe.c"
if ! file "$test_root/otel-health-probe" | grep -Fq 'statically linked'; then
  printf '%s\n' 'the probe is not statically linked for the distroless runtime' >&2
  exit 1
fi

config="$repo_root/deploy/otel-collector.yaml"
compose="$repo_root/deploy/compose.yaml"
dockerfile="$repo_root/deploy/Dockerfile.otel"
grep -Fq 'health_check:' "$config"
grep -Fq 'endpoint: 127.0.0.1:13133' "$config"
grep -Fq 'component_health:' "$config"
grep -Fq 'include_recoverable_errors: true' "$config"
grep -Fq 'recovery_duration: 30s' "$config"
if grep -Fq 'check_collector_pipeline' "$config"; then
  printf '%s\n' 'the deprecated pipeline health poller must not be configured' >&2
  exit 1
fi
grep -Fq 'Dockerfile.otel' "$compose"
grep -Fq 'extension.healthcheck.useComponentStatus' "$compose"
grep -Fq '/usr/local/bin/otel-health-probe' "$compose"
if grep -Eq 'published:.*13133|:13133:' "$compose"; then
  printf '%s\n' 'the Collector health endpoint must not be published on the host' >&2
  exit 1
fi
grep -Fq 'FROM docker.io/library/gcc:14-bookworm AS probe-builder' "$dockerfile"
grep -Fq 'FROM docker.io/otel/opentelemetry-collector-contrib:${OTEL_COLLECTOR_VERSION}' "$dockerfile"
grep -Fq 'HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3' "$dockerfile"

start_fixture() {
  local mode="$1"
  local status_code="$2"
  local body="$3"

  : >"$test_root/port"
  python3 - "$test_root/port" "$mode" "$status_code" "$body" <<'PY' &
import socket
import sys
import time
from pathlib import Path

port_file = Path(sys.argv[1])
mode = sys.argv[2]
status_code = sys.argv[3]
body = sys.argv[4].encode()
crlf = bytes((13, 10))

with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port_file.write_text(str(server.getsockname()[1]), encoding="ascii")
    with server.accept()[0] as client:
        client.recv(4096)
        if mode == "timeout":
            time.sleep(3.0)
        else:
            response = (
                f"HTTP/1.1 {status_code} Fixture".encode()
                + crlf
                + b"Content-Type: application/json"
                + crlf
                + b"Content-Length: "
                + str(len(body)).encode()
                + crlf
                + b"Connection: close"
                + crlf
                + crlf
                + body
            )
            client.sendall(response)
PY
  server_pid=$!
  for _ in $(seq 1 200); do
    if [[ -s "$test_root/port" ]]; then
      return 0
    fi
    sleep 0.01
  done
  printf '%s\n' 'fixture server did not publish a loopback port' >&2
  return 1
}

stop_fixture() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}

expect_failure() {
  local label="$1"
  local mode="$2"
  local status_code="$3"
  local body="$4"
  local status

  start_fixture "$mode" "$status_code" "$body"
  if "$test_root/otel-health-probe" --port "$(<"$test_root/port")"; then
    status=0
  else
    status=$?
  fi
  stop_fixture
  if [[ $status -eq 0 ]]; then
    printf 'probe accepted %s fixture\n' "$label" >&2
    exit 1
  fi
}

start_fixture response 200 '{"healthy":true,"status":"StatusOK","status_time":"2026-09-08T00:00:00Z"}'
if ! "$test_root/otel-health-probe" --port "$(<"$test_root/port")"; then
  printf '%s\n' 'probe rejected a healthy traces pipeline fixture' >&2
  exit 1
fi
stop_fixture

expect_failure 'healthy=false' response 200 '{"healthy":false,"status":"StatusOK"}'
expect_failure 'degraded status' response 200 '{"healthy":true,"status":"StatusRecoverableError"}'
expect_failure 'HTTP failure' response 503 '{"healthy":false,"status":"StatusStarting"}'
expect_failure 'malformed JSON' response 200 'not-json'

start_fixture timeout 200 '{}'
start_seconds="$(date +%s)"
if "$test_root/otel-health-probe" --port "$(<"$test_root/port")"; then
  status=0
else
  status=$?
fi
elapsed_seconds=$(( $(date +%s) - start_seconds ))
stop_fixture
if [[ $status -eq 0 || $elapsed_seconds -gt 4 ]]; then
  printf 'probe timeout contract failed: status=%s elapsed=%ss\n' "$status" "$elapsed_seconds" >&2
  exit 1
fi

printf '%s\n' 'Collector component-status config and native probe pass/fail/timeout tests passed.'
