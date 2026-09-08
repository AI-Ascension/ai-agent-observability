#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
server_pid=""
dependency_pid=""
trap 'if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi; if [[ -n "$dependency_pid" ]]; then kill "$dependency_pid" 2>/dev/null || true; fi; rm -r -- "$test_root"' EXIT

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
installer="$repo_root/deploy/install-otel-health-probe.sh"
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
if grep -Eq 'OTEL_HEALTH_PROBE_(MLFLOW|LAMINAR)_(HOST|PORT)' "$repo_root/deploy/otel-health-probe.c"; then
  printf '%s\n' 'the probe must derive active dependency endpoints from the mounted config' >&2
  exit 1
fi
bash -n "$installer"
grep -Fq 'OTEL_HEALTH_PROBE_INSTALL_APPROVED=true' "$installer"
grep -Fq 'OTEL_QUIESCE_APPROVED=true' "$installer"
grep -Fq 'OTEL_EXPECTED_BUILT_IMAGE_ID' "$installer"
grep -Fq 'OTEL_EXPECTED_ACTIVE_IMAGE_ID' "$installer"
grep -Fq 'OTEL_EXPECTED_DOCKERFILE_SHA256' "$installer"
grep -Fq 'OTEL_INSTALL_TIMEOUT_SECONDS' "$installer"
grep -Fq 'remaining_timeout' "$installer"
grep -Fq 'active traces exporter set does not match' "$installer"
grep -Fq 'active mounted Collector config hash' "$installer"
grep -Fq 'active Collector environment identity' "$installer"
grep -Fq 'previous-full-env-sha256' "$installer"
grep -Fq 'phase=verify-previous-runtime' "$installer"
grep -Fq 'active Collector inspect could not be sanitized' "$installer"
grep -Fq 'rollback UNKNOWN; manual reconciliation required' "$installer"
grep -Fq 'Collector image build' "$installer"
grep -Fq 'Collector service recreation' "$installer"
grep -Fq 'backup verification failed' "$installer"
grep -Fq 'rollback verified' "$installer"
grep -Fq 'compose=(podman compose --env-file "$env_file")' "$installer"
grep -Fq 'rollback_last_health' "$installer"
grep -Fq 'sys.stdout.write("\n")' "$installer"
grep -Fq 'StatusRecoverableError' "$repo_root/deploy/otel-health-probe.c"
if grep -Fq 'timeout --foreground' "$installer"; then
  printf '%s\n' 'the installer must use process-group timeouts' >&2
  exit 1
fi
if grep -Eq 'compose.*down|down.*-v|volume prune|image prune' "$installer"; then
  printf '%s\n' 'the guarded OTel installer contains a destructive cleanup path' >&2
  exit 1
fi

start_fixture() {
  local mode="$1"
  local status_code="$2"
  local body_arg="$3"

  : >"$test_root/port"
  python3 - "$test_root/port" "$mode" "$status_code" "$body_arg" <<'PY' &
import socket
import sys
import time
from pathlib import Path

port_file = Path(sys.argv[1])
mode = sys.argv[2]
status_code = sys.argv[3]
body_arg = sys.argv[4]
body = bytes.fromhex(body_arg) if mode == "hex" else body_arg.encode()
crlf = bytes((13, 10))

with socket.socket(socket.AF_INET) as server:
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
start_fixture response 200 '{"healthy":true,"status":"StatusRecoverableError"}'
if ! "$test_root/otel-health-probe" --port "$(<"$test_root/port")"; then
  printf '%s\n' 'probe rejected a recoverable healthy fixture' >&2
  exit 1
fi
stop_fixture
expect_failure 'HTTP failure' response 503 '{"healthy":false,"status":"StatusStarting"}'
expect_failure 'malformed JSON' response 200 'not-json'
expect_failure 'trailing JSON garbage' response 200 '{"healthy":true,"status":"StatusOK"} garbage'
expect_failure 'second JSON value' response 200 '{"healthy":true,"status":"StatusOK"}{}'
expect_failure 'trailing comma' response 200 '{"healthy":true,"status":"StatusOK",}'
expect_failure 'invalid unknown value' response 200 '{"healthy":true,"status":"StatusOK","extra":truex}'
expect_failure 'duplicate status key' response 200 '{"healthy":true,"status":"StatusOK","status":"StatusOK"}'
expect_failure 'duplicate unknown key' response 200 '{"healthy":true,"status":"StatusOK","extra":1,"extra":2}'
expect_failure 'raw NUL after JSON' hex 200 '7b226865616c746879223a747275652c22737461747573223a225374617475734f4b227d00'
expect_failure 'invalid raw UTF-8' hex 200 '7b226865616c746879223a747275652c22737461747573223a225374617475734f4b222c226578747261223a22ff227d'
expect_failure 'non-ASCII escape' hex 200 '7b226865616c746879223a747275652c22737461747573223a225374617475734f4b222c226578747261223a225c7530306539227d'

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

dependency_config="$test_root/dependency-config.yaml"
cat >"$dependency_config" <<'YAML'
exporters:
  otlp_http/mlflow:
    endpoint: http://resolver.test:0
service:
  pipelines:
    traces:
      exporters: [otlp_http/mlflow]
YAML

start_dependency_fixture() {
  local target_status="$1"
  local dns_mode="${2:-address}"
  local status_delay="${3:-0}"
  local target_delay="${4:-0}"

  : >"$test_root/status-port"
  : >"$test_root/target-port"
  : >"$test_root/dns-port"
  python3 - "$test_root/status-port" "$test_root/target-port" "$test_root/dns-port" \
    "$target_status" "$dns_mode" "$status_delay" "$target_delay" <<'PY' &
import socket
import struct
import sys
import threading
import time
from pathlib import Path

status_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
dns_path = Path(sys.argv[3])
target_status = sys.argv[4].encode("ascii")
dns_mode = sys.argv[5]
status_delay = float(sys.argv[6])
target_delay = float(sys.argv[7])

def serve(port_path, response_status, delay):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(2)
        port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
        while True:
            client, _ = server.accept()
            with client:
                client.recv(4096)
                if delay:
                    time.sleep(delay)
                body = b'{"healthy":true,"status":"StatusOK"}'
                response = (
                    b"HTTP/1.1 " + response_status + b" Fixture\r\n"
                    + b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n"
                    + b"Connection: close\r\n\r\n" + body
                )
                client.sendall(response)

def wire(name):
    return b"".join(bytes((len(label),)) + label.encode("ascii") for label in name.split(".")) + b"\x00"

def decode_qname(packet):
    position = 12
    labels = []
    while packet[position]:
        size = packet[position]
        position += 1
        labels.append(packet[position:position + size].decode("ascii"))
        position += size
    return ".".join(labels), position + 5

def answer(name, record_type, data):
    return wire(name) + struct.pack("!HHIH", record_type, 1, 60, len(data)) + data

def answer_wire(owner, record_type, data):
    return owner + struct.pack("!HHIH", record_type, 1, 60, len(data)) + data

def serve_dns():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind(("127.0.0.1", 0))
        dns_path.write_text(str(server.getsockname()[1]), encoding="ascii")
        packet, client = server.recvfrom(2048)
        query_name, question_end = decode_qname(packet)
        question = packet[12:question_end]
        if dns_mode == "address":
            answers = [answer(query_name.upper(), 1, socket.inet_aton("127.0.0.1"))]
        elif dns_mode == "compressed-address":
            answers = [answer_wire(b"\xc0\x0c", 1, socket.inet_aton("127.0.0.1"))]
        elif dns_mode == "chain":
            answers = [
                answer(query_name.upper(), 5, wire("ALIAS.TEST")),
                answer("alias.test", 1, socket.inet_aton("127.0.0.1")),
            ]
        elif dns_mode == "compressed-chain":
            first = answer_wire(b"\xc0\x0c", 5, wire("alias.test"))
            alias_offset = 12 + len(question) + 2 + 10
            second = answer_wire(bytes((0xc0 | (alias_offset >> 8), alias_offset & 0xff)),
                                 1, socket.inet_aton("127.0.0.1"))
            answers = [first, second]
        elif dns_mode == "unrelated":
            answers = [answer("other.test", 1, socket.inet_aton("127.0.0.1"))]
        elif dns_mode == "duplicate":
            answers = [
                answer(query_name, 1, socket.inet_aton("127.0.0.1")),
                answer(query_name, 1, socket.inet_aton("127.0.0.2")),
            ]
        elif dns_mode == "question-mismatch":
            question = wire("other.test") + struct.pack("!HH", 1, 1)
            answers = [answer(query_name, 1, socket.inet_aton("127.0.0.1"))]
        elif dns_mode == "loop":
            answers = [
                answer(query_name, 5, wire("alias.test")),
                answer("alias.test", 5, wire(query_name)),
            ]
        elif dns_mode == "compression-loop":
            answers = [answer_wire(b"\xc0\x1f", 1, socket.inet_aton("127.0.0.1"))]
        else:
            raise ValueError(dns_mode)
        header = packet[:2] + b"\x81\x80" + struct.pack("!HHHH", 1, len(answers), 0, 0)
        server.sendto(header + question + b"".join(answers), client)

threads = [
    threading.Thread(target=serve, args=(status_path, b"200", status_delay), daemon=True),
    threading.Thread(target=serve, args=(target_path, target_status, target_delay), daemon=True),
    threading.Thread(target=serve_dns, daemon=True),
]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
PY
  dependency_pid=$!
  for _ in $(seq 1 200); do
    if [[ -s "$test_root/status-port" && -s "$test_root/target-port" && -s "$test_root/dns-port" ]]; then
      return 0
    fi
    sleep 0.01
  done
  printf '%s\n' 'dependency fixture did not publish loopback ports' >&2
  return 1
}

stop_dependency_fixture() {
  if [[ -n "$dependency_pid" ]]; then
    kill "$dependency_pid" 2>/dev/null || true
    wait "$dependency_pid" 2>/dev/null || true
    dependency_pid=""
  fi
}

build_dependency_probe() {
  local status_port="$1"
  local target_port="$2"
  local dns_port_value="$3"

  sed -Ei "s#http://resolver\\.test:[0-9]+#http://resolver.test:$target_port#g" "$dependency_config"
  gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -static -s \
    -DOTEL_HEALTH_PROBE_DEFAULT_PORT="$status_port" \
    -DOTEL_HEALTH_PROBE_CONFIG_PATH=\"$dependency_config\" \
    -DOTEL_HEALTH_PROBE_DNS_SERVER=\"127.0.0.1\" \
    -DOTEL_HEALTH_PROBE_DNS_PORT="$dns_port_value" \
    -o "$test_root/otel-health-probe-dependencies" "$repo_root/deploy/otel-health-probe.c"
}

run_dependency_probe() {
  local mode="$1"
  local expected="$2"
  local status

  start_dependency_fixture 200 "$mode"
  build_dependency_probe "$(<"$test_root/status-port")" "$(<"$test_root/target-port")" "$(<"$test_root/dns-port")"
  if "$test_root/otel-health-probe-dependencies"; then
    status=0
  else
    status=$?
  fi
  stop_dependency_fixture
  if [[ "$expected" == success && "$status" -ne 0 ]]; then
    printf 'dependency probe rejected %s fixture\n' "$mode" >&2
    exit 1
  fi
  if [[ "$expected" == failure && "$status" -eq 0 ]]; then
    printf 'dependency probe accepted %s fixture\n' "$mode" >&2
    exit 1
  fi
}

run_dependency_probe address success
run_dependency_probe compressed-address success
run_dependency_probe chain success
run_dependency_probe compressed-chain success
run_dependency_probe unrelated failure
run_dependency_probe duplicate failure
run_dependency_probe question-mismatch failure
run_dependency_probe loop failure
run_dependency_probe compression-loop failure

cat >"$dependency_config" <<'YAML'
exporters:
  otlp_http/mlflow:
    headers:
      endpoint: http://resolver.test:0
service:
  pipelines:
    traces:
      exporters: [otlp_http/mlflow]
YAML
start_dependency_fixture 200 address
build_dependency_probe "$(<"$test_root/status-port")" "$(<"$test_root/target-port")" "$(<"$test_root/dns-port")"
if "$test_root/otel-health-probe-dependencies"; then
  printf '%s\n' 'probe accepted a nested exporter endpoint without a top-level endpoint' >&2
  exit 1
fi
stop_dependency_fixture

cat >"$dependency_config" <<'YAML'
# exporters: [otlp_http/laminar]
exporters:
  otlp_http/mlflow:
    endpoint: http://resolver.test:0
service:
  pipelines:
    metrics:
      exporters: [otlp_http/laminar]
    traces:
      exporters:
        - otlp_http/mlflow
YAML
start_dependency_fixture 200 address
build_dependency_probe "$(<"$test_root/status-port")" "$(<"$test_root/target-port")" "$(<"$test_root/dns-port")"
if ! "$test_root/otel-health-probe-dependencies"; then
  printf '%s\n' 'probe misread another pipeline or comment as an active exporter' >&2
  exit 1
fi
stop_dependency_fixture

cat >"$dependency_config" <<'YAML'
exporters:
  otlp_http/mlflow:
    endpoint: http://resolver.test:0
service:
  pipelines:
    traces:
      exporters: [otlp_http/unknown]
YAML
start_dependency_fixture 200 address
build_dependency_probe "$(<"$test_root/status-port")" "$(<"$test_root/target-port")" "$(<"$test_root/dns-port")"
if "$test_root/otel-health-probe-dependencies"; then
  printf '%s\n' 'probe accepted an unknown active exporter' >&2
  exit 1
fi
stop_dependency_fixture

cat >"$dependency_config" <<'YAML'
exporters:
  otlp_http/mlflow:
    endpoint: http://resolver.test:0
service:
  pipelines:
    traces:
      exporters: [otlp_http/mlflow]
YAML
start_dependency_fixture 200 address 1.2 1.2
build_dependency_probe "$(<"$test_root/status-port")" "$(<"$test_root/target-port")" "$(<"$test_root/dns-port")"
start_seconds="$(date +%s)"
if "$test_root/otel-health-probe-dependencies"; then
  status=0
else
  status=$?
fi
elapsed_seconds=$(( $(date +%s) - start_seconds ))
stop_dependency_fixture
if [[ "$status" -eq 0 || "$elapsed_seconds" -gt 4 ]]; then
  printf 'dependency overall deadline failed: status=%s elapsed=%ss\n' "$status" "$elapsed_seconds" >&2
  exit 1
fi

printf '%s\n' 'Collector component-status config, native probe, resolver, dependency, and deadline tests passed.'
