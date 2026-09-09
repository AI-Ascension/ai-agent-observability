#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/deploy/install-otel-health-probe.sh"
test_root="$(mktemp -d)"
metrics_pid=""
dirty_fixture="$repo_root/.otel-installer-dirty-fixture"
cleanup() {
  rm -f -- "$dirty_fixture"
  if [[ -n "$metrics_pid" ]]; then
    kill "$metrics_pid" 2>/dev/null || true
    wait "$metrics_pid" 2>/dev/null || true
  fi
  [[ "${OTEL_TEST_KEEP:-}" == true ]] || rm -rf -- "$test_root"
}
trap cleanup EXIT

bash -n "$installer"
python3 - "$installer" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    "entrypoint: ($c.Config.Entrypoint // [])",
    "cmd: ($c.Config.Cmd // [])",
    "exposed_ports:",
    "port_bindings:",
    "networks:",
    "devices:",
    "device_requests:",
    "resources:",
    "previous-runtime-sha256",
    "OTEL_EXPECTED_ACTIVE_CONFIG_SHA256",
    "OTEL_EXPECTED_SOURCE_MANIFEST_SHA256",
    "verify_source_tree",
    "source checkout is dirty",
    "source tree does not match OTEL_EXPECTED_GIT_HEAD",
    "OTEL_QUIESCE_PROOF",
    "OTEL_ROLLBACK_TIMEOUT_SECONDS",
    "OTEL_METRICS_URL",
    "OTEL_EXPECTED_METRICS_PORT",
    "metrics_port_binding_state",
    "runtime_identity_stable_sha256",
    "configured loopback metrics endpoint",
    "OTEL_EXPECTED_TRACE_RECEIVERS",
    "otelcol_exporter_queue_size",
    "OTEL_EXPECTED_TRACE_RECEIVER_SERIES",
    "metrics_port_binding_contract_matches",
    "network_namespace_pin",
    "State.Status",
    "active_netns_pin",
    "candidate_command_contract_matches",
    "StartPeriod == 30000000000",
    "source materialization manifest",
    "healthcheck_contract_matches",
    "restore_backups_if_unchanged",
    "runtime_mutation_attempted",
    "runtime_mutation_may_have_changed",
)
missing = [needle for needle in required if needle not in source]
if missing:
    raise SystemExit(f"installer contract is missing: {', '.join(missing)}")
if "timeout --foreground" in source:
    raise SystemExit("installer uses a timeout mode that leaves grandchildren running")
if source.count("image_tag_mutated=true") != 1:
    raise SystemExit("image tag mutation marker is not single and explicit")
if source.index("image_tag_mutated=true") > source.index("bounded_run 'Collector image build'"):
    raise SystemExit("image build is not covered by image compensation")
if source.count("runtime_mutation_attempted=true") != 1:
    raise SystemExit("runtime mutation marker is not single and explicit")
if source.index("runtime_mutation_attempted=true") < source.index("pre-recreate live Collector quiescence"):
    raise SystemExit("runtime mutation begins before the immediate quiescence recheck")
PY

fake_bin="$test_root/bin"
state_dir="$test_root/state"
mkdir -p -- "$fake_bin" "$state_dir"
env_file="$test_root/.env"
metrics_mode_file="$test_root/metrics-mode"
printf '%s\n' normal >"$metrics_mode_file"
metrics_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
cat >"$env_file" <<'ENV'
BIND_ADDRESS=127.0.0.1
OTEL_METRICS_PORT=18888
MLFLOW_EXPERIMENT_ID=0
LAMINAR_PROJECT_API_KEY=fixture-key
ENV
sed -i "s/^OTEL_METRICS_PORT=.*/OTEL_METRICS_PORT=$metrics_port/" "$env_file"

collector_config="$repo_root/deploy/otel-collector.yaml"
expected_mount_source="$(readlink -f "$collector_config")"
legacy_config="$test_root/legacy-collector.yaml"
printf '%s\n' 'legacy baseline config without the candidate health extension' >"$legacy_config"
legacy_config_sha256="$(sha256sum "$legacy_config" | awk '{print $1}')"
cat >"$state_dir/inspect.json" <<JSON
[{"Id":"fixture-container-id","Name":"/ai-agent-observability-otel-collector","Image":"sha256:fixture-active","Created":"2026-09-08T00:00:00Z","Config":{"Entrypoint":[],"Cmd":["--feature-gates=+extension.healthcheck.useComponentStatus","--config=/etc/otelcol-contrib/config.yaml"],"ExposedPorts":{"4317/tcp":{},"4318/tcp":{},"8888/tcp":{}},"Env":["MLFLOW_EXPERIMENT_ID=0","LAMINAR_PROJECT_API_KEY=fixture-key"],"Healthcheck":{"Test":["CMD","/usr/local/bin/otel-health-probe"],"Interval":30000000000,"Timeout":5000000000,"Retries":3,"StartPeriod":30000000000},"Labels":{"com.docker.compose.project":"ai-agent-observability","com.docker.compose.service":"otel-collector"},"ReadonlyRootfs":true,"User":"","WorkingDir":"/"},"HostConfig":{"PortBindings":{"4317/tcp":[{"HostIp":"127.0.0.1","HostPort":"14317"}],"4318/tcp":[{"HostIp":"127.0.0.1","HostPort":"14318"}],"8888/tcp":[{"HostIp":"127.0.0.1","HostPort":"$metrics_port"}]},"PublishAllPorts":false,"NetworkMode":"ai-agent-observability_default","ExtraHosts":[],"Devices":[],"DeviceRequests":[],"BlkioWeight":0,"CpuCount":0,"CpuPercent":0,"CpuPeriod":0,"CpuQuota":0,"CpuRealtimePeriod":0,"CpuRealtimeRuntime":0,"CpuShares":0,"CpusetCpus":"","CpusetMems":"","NanoCpus":0,"Memory":0,"MemoryReservation":0,"MemorySwap":0,"MemorySwappiness":0,"OomKillDisable":false,"PidsLimit":0,"Ulimits":[],"ReadonlyRootfs":true,"SecurityOpt":["no-new-privileges:true"],"CapAdd":[],"CapDrop":[],"Privileged":false,"Tmpfs":{"/tmp":"rw"},"RestartPolicy":{"Name":"unless-stopped"}},"NetworkSettings":{"Networks":{"ai-agent-observability_default":{"Aliases":["otel-collector","ai-agent-observability-otel-collector"],"IPAddress":"10.89.0.9"}}},"Mounts":[{"Type":"bind","Source":"$expected_mount_source","Destination":"/etc/otelcol-contrib/config.yaml","Mode":"ro","RW":false}],"State":{"Status":"running","Pid":12345,"Health":{"Status":"healthy","Log":[]}}}]
JSON
expected_active_healthcheck_sha256="$(jq -cS '.[0].Config.Healthcheck // null' "$state_dir/inspect.json" | sha256sum | awk '{print $1}')"
jq '.[0].Config.Healthcheck = null | .[0].State |= del(.Health)' \
  "$state_dir/inspect.json" >"$state_dir/inspect-missing-health.json"
missing_active_healthcheck_sha256="$(jq -cS '.[0].Config.Healthcheck // null' "$state_dir/inspect-missing-health.json" | sha256sum | awk '{print $1}')"
jq '.[0].Config.Cmd = ["--config=/etc/otelcol-contrib/config.yaml"] | .[0].Config.Healthcheck = null | .[0].State |= del(.Health) | .[0].HostConfig.PortBindings |= with_entries(select(.key != "8888/tcp"))' \
  "$state_dir/inspect.json" >"$state_dir/inspect-legacy.json"

cat >"$fake_bin/podman" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

log_file="${FAKE_LOG:?}"
state_dir="${FAKE_STATE_DIR:?}"
printf '%s\n' "$*" >>"$log_file"

inspect_json() {
  local source="$state_dir/inspect.json"
  if [[ -e "$state_dir/recreated" ]]; then
    if [[ -e "$state_dir/rollback-recreated" ]]; then
      if [[ "${FAKE_LEGACY_BASELINE:-}" == yes ]]; then
        source="$state_dir/inspect-legacy.json"
      elif [[ "${FAKE_MISSING_HEALTH:-}" == yes ]]; then
        source="$state_dir/inspect-missing-health.json"
      fi
      jq '.[0].Id = "fixture-rollback-id" | .[0].Image = "sha256:fixture-active"' "$source"
    elif [[ "${FAKE_POST_RECREATE_DRIFT:-}" == yes ]]; then
      if [[ "${FAKE_MISSING_HEALTH:-}" == yes ]]; then
        source="$state_dir/inspect-missing-health.json"
      fi
      jq '.[0].Id = "fixture-new-id" | .[0].Image = "sha256:fixture-built" | .[0].Config.WorkingDir = "/drift"' "$source"
    else
      jq '.[0].Id = "fixture-new-id" | .[0].Image = "sha256:fixture-built"' "$source"
    fi
  elif [[ -e "$state_dir/id-changed" ]]; then
    jq '.[0].Id = "fixture-concurrent-id"' "$source"
  elif [[ -e "$state_dir/runtime-drift" ]]; then
    jq '.[0].Config.WorkingDir = "/drift"' "$source"
  elif [[ "${FAKE_STOPPED:-}" == yes ]]; then
    jq '.[0].State.Status = "exited"' "$source"
  else
    if [[ "${FAKE_LEGACY_BASELINE:-}" == yes ]]; then
      source="$state_dir/inspect-legacy.json"
    elif [[ "${FAKE_MISSING_HEALTH:-}" == yes ]]; then
      source="$state_dir/inspect-missing-health.json"
    fi
    if [[ "${FAKE_BAD_METRICS_BIND:-}" == yes ]]; then
      jq '.[0].HostConfig.PortBindings["8888/tcp"][0].HostIp = "0.0.0.0"' "$source"
    elif [[ "${FAKE_BAD_HEALTH:-}" == yes ]]; then
      jq '.[0].Config.Healthcheck.Retries = 2' "$source"
    else
      cat "$source"
    fi
  fi
}

if [[ "${1:-}" == compose ]]; then
  if [[ " $* " == *" config "* ]]; then
    if [[ " $* " == *" --quiet "* ]]; then
      exit 0
    fi
    cat <<'YAML'
name: ai-agent-observability
services:
  otel-collector:
    image: localhost/ai-ascension/ai-agent-observability/otel-collector:0.160.0
YAML
    exit 0
  fi
  if [[ " $* " == *" build "* ]]; then
    printf '%s\n' 'fixture build stdout'
    if [[ "${FAKE_OUTPUT_OVERFLOW:-}" == yes ]]; then
      python3 -c 'import sys; sys.stdout.write("x" * 200000)'
    fi
    if [[ "${FAKE_BUILD_TIMEOUT:-}" == yes ]]; then
      (sleep 30) &
      wait
    fi
    if [[ "${FAKE_BUILD_FAIL:-}" == yes ]]; then
      printf '%s\n' 'fixture build failure' >&2
      exit 42
    fi
    if [[ "${FAKE_ID_CHANGE:-}" == yes ]]; then
      : >"$state_dir/id-changed"
    fi
    if [[ "${FAKE_RUNTIME_DRIFT:-}" == yes ]]; then
      : >"$state_dir/runtime-drift"
    fi
    : >"$state_dir/built"
    exit 0
  fi
  if [[ " $* " == *" up "* ]]; then
    if [[ "${FAKE_RECREATE_FAIL:-}" == yes ]]; then
      : >"$state_dir/recreate-attempted"
      exit 43
    fi
    : >"$state_dir/recreated"
    if [[ -e "$state_dir/retagged" ]]; then
      : >"$state_dir/rollback-recreated"
    fi
    exit 0
  fi
  exit 0
fi

if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
  if [[ -e "$state_dir/retagged" ]]; then
    printf '%s\n' 'sha256:fixture-active'
  elif [[ -e "$state_dir/built" ]]; then
    printf '%s\n' 'sha256:fixture-built'
  else
    printf '%s\n' 'sha256:fixture-active'
  fi
  exit 0
fi

if [[ "${1:-}" == image && "${2:-}" == tag ]]; then
  if [[ "${FAKE_ROLLBACK_UNKNOWN:-}" == yes ]]; then
    exit 41
  fi
  : >"$state_dir/retagged"
  exit 0
fi

if [[ "${1:-}" == inspect ]]; then
  if [[ " $* " == *" --format "* ]]; then
    format="${3:-}"
    case "$format" in
      *'.Id'*)
        if [[ -e "$state_dir/recreated" ]]; then
          if [[ -e "$state_dir/rollback-recreated" ]]; then
            printf '%s\n' fixture-rollback-id
          else
            printf '%s\n' fixture-new-id
          fi
        elif [[ -e "$state_dir/id-changed" ]]; then
          printf '%s\n' fixture-concurrent-id
        else
          printf '%s\n' fixture-container-id
        fi
        ;;
      *'.Image'*)
        if [[ -e "$state_dir/recreated" && ! -e "$state_dir/rollback-recreated" ]]; then
          printf '%s\n' 'sha256:fixture-built'
        else
          printf '%s\n' 'sha256:fixture-active'
        fi
        ;;
      *'com.docker.compose.project'*)
        printf '%s\t%s\n' 'ai-agent-observability' 'otel-collector'
        ;;
      *'.Mounts'*)
        printf 'bind\t%s\t%s\tfalse\tro\n' "${FAKE_MOUNT_SOURCE:?}" '/etc/otelcol-contrib/config.yaml'
        ;;
      *'Healthcheck.Test'*)
        printf '%s\n' '["CMD","/usr/local/bin/otel-health-probe"]'
        ;;
      *'.Config.Env'*)
        printf '%s\n' 'MLFLOW_EXPERIMENT_ID=0' 'LAMINAR_PROJECT_API_KEY=fixture-key'
        ;;
      *'.State.Health'*)
        if [[ "${FAKE_LEGACY_BASELINE:-}" == yes && ! -e "$state_dir/recreated" ]]; then
          printf '%s\n' missing
        elif [[ "${FAKE_MISSING_HEALTH:-}" == yes && ( ! -e "$state_dir/recreated" || -e "$state_dir/rollback-recreated" ) ]]; then
          printf '%s\n' missing
        else
          printf '%s\n' healthy
        fi
        ;;
      *)
        printf '%s\n' 'unsupported fixture inspect format' >&2
        exit 1
        ;;
    esac
  else
    inspect_json
  fi
  exit 0
fi

if [[ "${1:-}" == cp ]]; then
  destination="${@: -1}"
  config_source="${FAKE_CONFIG:?}"
  if [[ "${FAKE_LEGACY_BASELINE:-}" == yes && ! -e "$state_dir/recreated" && -n "${FAKE_ACTIVE_CONFIG:-}" ]]; then
    config_source="$FAKE_ACTIVE_CONFIG"
  fi
  cp "$config_source" "$destination"
  exit 0
fi

printf 'unsupported fixture podman invocation: %s\n' "$*" >&2
exit 1
FAKE
chmod +x "$fake_bin/podman"

cat >"$fake_bin/nsenter" <<'FAKE_NSENTER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FAKE_NSENTER_LOG:?}"
[[ "${1:-}" == --target && "${3:-}" == --net && "${4:-}" == python3 ]] || {
  printf '%s\n' 'namespace reader did not receive --target PID --net python3' >&2
  exit 2
}
target_pid="$2"
[[ "$target_pid" =~ ^[1-9][0-9]*$ && -e "/proc/$target_pid/ns/net" ]] || {
  printf '%s\n' 'namespace reader target PID is not live' >&2
  exit 3
}
shift 4
url="${2:-}"
if [[ "$url" == http://127.0.0.1:8888/metrics && -n "${FAKE_NAMESPACE_METRICS_URL:-}" ]]; then
  set -- "$1" "${FAKE_NAMESPACE_METRICS_URL}" "${@:3}"
fi
exec python3 "$@"
FAKE_NSENTER
chmod +x "$fake_bin/nsenter"

cat >"$test_root/metrics-server.py" <<'PY'
import http.server
import os
import sys

port = int(sys.argv[1])
payload = """# TYPE otelcol_exporter_queue_size gauge
otelcol_exporter_queue_size{exporter=\"otlp_http/mlflow\"} 0
otelcol_exporter_queue_size{exporter=\"otlp_http/laminar\"} 0
# TYPE otelcol_exporter_in_flight_requests gauge
otelcol_exporter_in_flight_requests{exporter=\"otlp_http/mlflow\"} 0
otelcol_exporter_in_flight_requests{exporter=\"otlp_http/laminar\"} 0
# TYPE otelcol_receiver_accepted_spans counter
otelcol_receiver_accepted_spans{receiver=\"otlp\",transport=\"http\"} 10
otelcol_receiver_accepted_spans{receiver=\"otlp\",transport=\"grpc\"} 10
""".encode()

mode_file = os.environ["FAKE_METRICS_MODE_FILE"]

def response_payload():
    mode = open(mode_file, encoding="utf-8").read().strip()
    text = payload.decode()
    if mode == "missing-exporter":
        text = text.replace('otelcol_exporter_queue_size{exporter="otlp_http/laminar"} 0\n', "")
        text = text.replace('otelcol_exporter_in_flight_requests{exporter="otlp_http/laminar"} 0\n', "")
    elif mode == "duplicate-exporter":
        text += 'otelcol_exporter_queue_size{exporter="otlp_http/mlflow"} 0\n'
    elif mode == "duplicate-receiver":
        text += 'otelcol_receiver_accepted_spans{receiver="otlp",transport="http"} 10\n'
    elif mode == "malformed":
        text += 'otelcol_exporter_queue_size{exporter="otlp_http/mlflow"} broken\n'
    return text.encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        body = response_payload()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
FAKE_METRICS_MODE_FILE="$metrics_mode_file" python3 -u "$test_root/metrics-server.py" "$metrics_port" &
metrics_pid=$!
for _ in $(seq 1 20); do
  if python3 - "$metrics_port" <<'PY'
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2):
    pass
PY
  then
    break
  fi
  sleep 0.05
done
jq --argjson pid "$metrics_pid" '.[0].State.Pid = $pid' "$state_dir/inspect.json" >"$state_dir/inspect.json.tmp"
mv "$state_dir/inspect.json.tmp" "$state_dir/inspect.json"
jq --argjson pid "$metrics_pid" '.[0].State.Pid = $pid' "$state_dir/inspect-legacy.json" >"$state_dir/inspect-legacy.json.tmp"
mv "$state_dir/inspect-legacy.json.tmp" "$state_dir/inspect-legacy.json"

log_file="$test_root/check.log"
: >"$log_file"
common_env=(
  OTEL_ENGINE=podman
  OTEL_COMPOSE_PROJECT=ai-agent-observability
  OTEL_CONTAINER_NAME=ai-agent-observability-otel-collector
  OTEL_ENV_FILE="$env_file"
  OTEL_METRICS_URL="http://127.0.0.1:$metrics_port/metrics"
  OTEL_BACKUP_ROOT="$test_root/check-backups"
  OTEL_EXPECTED_GIT_HEAD="$(git -C "$repo_root" rev-parse HEAD)"
  OTEL_EXPECTED_PROBE_SHA256="$(sha256sum "$repo_root/deploy/otel-health-probe.c" | awk '{print $1}')"
  OTEL_EXPECTED_CONFIG_SHA256="$(sha256sum "$collector_config" | awk '{print $1}')"
  OTEL_EXPECTED_ACTIVE_CONFIG_SHA256="$(sha256sum "$collector_config" | awk '{print $1}')"
  OTEL_EXPECTED_COMPOSE_SHA256="$(sha256sum "$repo_root/deploy/compose.yaml" | awk '{print $1}')"
  OTEL_EXPECTED_DOCKERFILE_SHA256="$(sha256sum "$repo_root/deploy/Dockerfile.otel" | awk '{print $1}')"
  OTEL_EXPECTED_ACTIVE_IMAGE_ID=sha256:fixture-active
  OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256="$expected_active_healthcheck_sha256"
  OTEL_EXPECTED_TRACE_EXPORTERS=otlp_http/mlflow,otlp_http/laminar
  OTEL_EXPECTED_TRACE_RECEIVERS=otlp
  OTEL_EXPECTED_TRACE_RECEIVER_SERIES=otlp/http,otlp/grpc
  FAKE_LOG="$log_file"
  FAKE_STATE_DIR="$state_dir"
  FAKE_CONFIG="$collector_config"
  FAKE_MOUNT_SOURCE="$expected_mount_source"
)

if ! env "${common_env[@]}" PATH="$fake_bin:$PATH" \
    "$installer" --check >"$test_root/check.out" 2>"$test_root/check.err"; then
  cat "$test_root/check.err" >&2
  exit 1
fi
grep -Fq -- "--env-file $env_file" "$log_file"
grep -Fq 'no mutation performed' "$test_root/check.out"

printf '%s\n' 'unreviewed source drift' >"$dirty_fixture"
if env "${common_env[@]}" PATH="$fake_bin:$PATH" \
    "$installer" --check >"$test_root/dirty-check.out" 2>"$test_root/dirty-check.err"; then
  printf '%s\n' 'installer accepted an unrelated dirty source path' >&2
  exit 1
fi
grep -Fq 'source checkout is dirty' "$test_root/dirty-check.err"
rm -f -- "$dirty_fixture"

missing_check_log="$test_root/missing-check.log"
: >"$missing_check_log"
if ! env "${common_env[@]}" \
    OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256="$missing_active_healthcheck_sha256" \
    FAKE_MISSING_HEALTH=yes FAKE_LOG="$missing_check_log" PATH="$fake_bin:$PATH" \
    "$installer" --check >"$test_root/missing-check.out" 2>"$test_root/missing-check.err"; then
  cat "$test_root/missing-check.err" >&2
  printf '%s\n' 'installer rejected a legacy baseline with no Docker healthcheck' >&2
  exit 1
fi
grep -Fq 'no mutation performed' "$test_root/missing-check.out"

legacy_env_file="$test_root/legacy.env"
grep -v '^OTEL_METRICS_PORT=' "$env_file" >"$legacy_env_file"
legacy_check_log="$test_root/legacy-check.log"
: >"$legacy_check_log"
if ! env "${common_env[@]}" \
    OTEL_ENV_FILE="$legacy_env_file" OTEL_EXPECTED_METRICS_PORT="$metrics_port" \
    OTEL_METRICS_URL=http://127.0.0.1:8888/metrics \
    OTEL_EXPECTED_ACTIVE_CONFIG_SHA256="$legacy_config_sha256" \
    OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256="$missing_active_healthcheck_sha256" \
    FAKE_LEGACY_BASELINE=yes FAKE_ACTIVE_CONFIG="$legacy_config" FAKE_LOG="$legacy_check_log" PATH="$fake_bin:$PATH" \
    "$installer" --check >"$test_root/legacy-check.out" 2>"$test_root/legacy-check.err"; then
  cat "$test_root/legacy-check.err" >&2
  printf '%s\n' 'installer rejected an empty-health legacy baseline without a host metrics binding' >&2
  exit 1
fi
grep -Fq 'no mutation performed' "$test_root/legacy-check.out"

proof="$test_root/quiescence.json"
refresh_proof() {
  local new_stamp
  new_stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat >"$proof" <<JSON
{"schema":"otel-quiescence-approval-v1","approved":true,"project":"ai-agent-observability","service":"otel-collector","container":"ai-agent-observability-otel-collector","container_id":"fixture-container-id","approved_at_utc":"$new_stamp"}
JSON
}
refresh_proof

install_log="$test_root/install.log"
: >"$install_log"
install_env=(
  "${common_env[@]}"
  OTEL_BACKUP_ROOT="$test_root/install-backups"
  OTEL_HEALTH_PROBE_INSTALL_APPROVED=true
  OTEL_QUIESCE_APPROVED=true
  OTEL_QUIESCE_PROOF="$proof"
  OTEL_QUIESCE_MAX_AGE_SECONDS=3600
  OTEL_EXPECTED_BUILT_IMAGE_ID=sha256:fixture-built
  OTEL_BUILD_TIMEOUT_SECONDS=10
  OTEL_RECREATE_TIMEOUT_SECONDS=10
  OTEL_INSPECT_TIMEOUT_SECONDS=2
  OTEL_INSTALL_TIMEOUT_SECONDS=180
  OTEL_ROLLBACK_TIMEOUT_SECONDS=30
  OTEL_READY_TIMEOUT_SECONDS=10
  OTEL_MAX_CAPTURE_BYTES=65536
)

legacy_namespace_log="$test_root/legacy-namespace.log"
refresh_proof
if ! env "${install_env[@]}" \
    OTEL_ENV_FILE="$legacy_env_file" OTEL_EXPECTED_METRICS_PORT="$metrics_port" \
    OTEL_METRICS_URL=http://127.0.0.1:8888/metrics \
    OTEL_EXPECTED_ACTIVE_CONFIG_SHA256="$legacy_config_sha256" \
    OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256="$missing_active_healthcheck_sha256" \
    FAKE_LEGACY_BASELINE=yes FAKE_ACTIVE_CONFIG="$legacy_config" \
    FAKE_NSENTER_LOG="$legacy_namespace_log" FAKE_NAMESPACE_METRICS_URL="http://127.0.0.1:$metrics_port/metrics" \
    FAKE_LOG="$test_root/legacy-install.log" PATH="$fake_bin:$PATH" \
    "$installer" --install >"$test_root/legacy-install.out" 2>"$test_root/legacy-install.err"; then
  cat "$test_root/legacy-install.err" >&2
  printf '%s\n' 'installer rejected the real legacy config and namespace metrics path' >&2
  exit 1
fi
grep -Fq 'OTel Collector installed and identity-verified healthy' "$test_root/legacy-install.out"
grep -Fq -- "--target $metrics_pid --net python3" "$legacy_namespace_log"
[[ "$(wc -l <"$legacy_namespace_log")" -ge 2 ]] || {
  printf '%s\n' 'legacy install did not observe the namespace metrics endpoint twice' >&2
  exit 1
}
rm -f "$state_dir"/{built,retagged,recreated,rollback-recreated,recreate-attempted,id-changed,runtime-drift}

run_expected_install_failure() {
  local label="$1"
  local expected="$2"
  local status=0
  local output_prefix="$test_root/negative-$label"
  : >"$output_prefix.out"
  : >"$output_prefix.err"
  refresh_proof
  if env "${install_env[@]}" FAKE_LOG="$output_prefix.log" PATH="$fake_bin:$PATH" \
      "$installer" --install >"$output_prefix.out" 2>"$output_prefix.err"; then
    printf 'installer unexpectedly accepted negative fixture: %s\n' "$label" >&2
    exit 1
  else
    status=$?
  fi
  [[ "$status" != 0 ]] || exit 1
  grep -Fq "$expected" "$output_prefix.err" || {
    cat "$output_prefix.err" >&2
    printf 'negative fixture did not report the expected guard: %s\n' "$label" >&2
    exit 1
  }
  [[ ! -e "$state_dir/built" && ! -e "$state_dir/recreated" ]] || {
    printf 'negative fixture mutated the service: %s\n' "$label" >&2
    exit 1
  }
}

for negative_mode in missing-exporter duplicate-exporter duplicate-receiver malformed; do
  printf '%s\n' "$negative_mode" >"$metrics_mode_file"
  run_expected_install_failure "$negative_mode" 'live Collector metrics did not prove pre-build quiescence'
done
printf '%s\n' normal >"$metrics_mode_file"

if env "${common_env[@]}" FAKE_BAD_METRICS_BIND=yes PATH="$fake_bin:$PATH" \
    "$installer" --check >"$test_root/bad-bind.out" 2>"$test_root/bad-bind.err"; then
  printf '%s\n' 'installer accepted an unrelated loopback metrics binding' >&2
  exit 1
fi
grep -Fq 'does not own the configured loopback metrics port' "$test_root/bad-bind.err"
if env "${common_env[@]}" FAKE_BAD_HEALTH=yes PATH="$fake_bin:$PATH" \
    "$installer" --check >"$test_root/bad-health.out" 2>"$test_root/bad-health.err"; then
  printf '%s\n' 'installer accepted a healthcheck timing drift' >&2
  exit 1
fi
grep -Fq 'healthcheck contract' "$test_root/bad-health.err"

status=0
refresh_proof
if env "${install_env[@]}" FAKE_BUILD_FAIL=yes FAKE_LOG="$install_log" PATH="$fake_bin:$PATH" \
    "$installer" --install >"$test_root/install.out" 2>"$test_root/install.err"; then
  status=0
else
  status=$?
fi
[[ "$status" == 42 ]] || {
  cat "$test_root/install.err" >&2
  printf 'expected failed build to preserve status 42, got %s\n' "$status" >&2
  exit 1
}
grep -Fq 'rollback verified' "$test_root/install.err"
if grep -Fq 'fixture build stdout' "$test_root/install.out"; then
  printf '%s\n' 'bounded_run leaked raw engine output' >&2
  exit 1
fi
grep -Fq 'image tag' "$install_log"
if grep -Fq 'up -d --no-build --no-deps --force-recreate otel-collector' "$install_log"; then
  printf '%s\n' 'build failure unnecessarily recreated the active Collector' >&2
  exit 1
fi
[[ -e "$state_dir/retagged" && ! -e "$state_dir/recreated" ]] || exit 1
if grep -Fq 'rollback UNKNOWN' "$test_root/install.err"; then
  printf '%s\n' 'fixture build failure did not complete verified rollback' >&2
  exit 1
fi

rm -f "$state_dir"/built "$state_dir"/retagged "$state_dir"/recreated \
  "$state_dir"/rollback-recreated "$state_dir"/recreate-attempted "$state_dir"/id-changed \
  "$state_dir"/runtime-drift
missing_rollback_log="$test_root/missing-rollback.log"
: >"$missing_rollback_log"
refresh_proof
status=0
if env "${install_env[@]}" \
    OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256="$missing_active_healthcheck_sha256" \
    FAKE_MISSING_HEALTH=yes FAKE_POST_RECREATE_DRIFT=yes FAKE_LOG="$missing_rollback_log" \
    PATH="$fake_bin:$PATH" "$installer" --install >"$test_root/missing-rollback.out" \
    2>"$test_root/missing-rollback.err"; then
  status=0
else
  status=$?
fi
[[ "$status" == 1 ]] || {
  cat "$test_root/missing-rollback.err" >&2
  printf 'expected missing-health baseline rollback fixture to preserve status 1, got %s\n' "$status" >&2
  exit 1
}
grep -Fq 'post-install identity verification failed' "$test_root/missing-rollback.err"
grep -Fq 'rollback verified' "$test_root/missing-rollback.err"
grep -Fq 'up -d --no-build --no-deps --force-recreate otel-collector' "$missing_rollback_log"
[[ -e "$state_dir/rollback-recreated" ]] || {
  printf '%s\n' 'missing-health baseline rollback did not recreate the legacy service' >&2
  exit 1
}

rm -f "$state_dir"/built "$state_dir"/retagged "$state_dir"/recreated \
  "$state_dir"/rollback-recreated "$state_dir"/recreate-attempted "$state_dir"/id-changed \
  "$state_dir"/runtime-drift

runtime_drift_log="$test_root/runtime-drift.log"
: >"$runtime_drift_log"
status=0
refresh_proof
if env "${install_env[@]}" FAKE_RUNTIME_DRIFT=yes FAKE_LOG="$runtime_drift_log" PATH="$fake_bin:$PATH" \
    "$installer" --install >"$test_root/runtime-drift.out" 2>"$test_root/runtime-drift.err"; then
  status=0
else
  status=$?
fi
[[ "$status" == 1 ]] || {
  cat "$test_root/runtime-drift.err" >&2
  printf 'expected post-build runtime drift to preserve status 1, got %s\n' "$status" >&2
  exit 1
}
grep -Fq 'runtime contract changed during image build' "$test_root/runtime-drift.err"
grep -Fq 'rollback verified' "$test_root/runtime-drift.err"
if grep -Fq 'up -d --no-build --no-deps --force-recreate otel-collector' "$runtime_drift_log"; then
  printf '%s\n' 'post-build runtime drift unnecessarily recreated the active Collector' >&2
  exit 1
fi
rm -f "$state_dir"/built "$state_dir"/retagged "$state_dir"/recreated \
  "$state_dir"/rollback-recreated "$state_dir"/recreate-attempted "$state_dir"/id-changed \
  "$state_dir"/runtime-drift

success_log="$test_root/success.log"
: >"$success_log"
success_env=(
  "${common_env[@]}"
  OTEL_BACKUP_ROOT="$test_root/success-backups"
  OTEL_HEALTH_PROBE_INSTALL_APPROVED=true
  OTEL_QUIESCE_APPROVED=true
  OTEL_QUIESCE_PROOF="$proof"
  OTEL_EXPECTED_BUILT_IMAGE_ID=sha256:fixture-built
  OTEL_BUILD_TIMEOUT_SECONDS=10
  OTEL_RECREATE_TIMEOUT_SECONDS=10
  OTEL_INSPECT_TIMEOUT_SECONDS=2
  OTEL_INSTALL_TIMEOUT_SECONDS=180
  OTEL_ROLLBACK_TIMEOUT_SECONDS=30
  OTEL_READY_TIMEOUT_SECONDS=10
  OTEL_MAX_CAPTURE_BYTES=65536
)
refresh_proof
if ! env "${success_env[@]}" FAKE_LOG="$success_log" PATH="$fake_bin:$PATH" \
    "$installer" --install >"$test_root/success.out" 2>"$test_root/success.err"; then
  cat "$test_root/success.err" >&2
  exit 1
fi
grep -Fq 'OTel Collector installed and identity-verified healthy' "$test_root/success.out"
if grep -Fq 'rollback' "$test_root/success.err"; then
  printf '%s\n' 'successful fixture install unexpectedly entered rollback' >&2
  exit 1
fi
grep -Fq 'build otel-collector' "$success_log"
grep -Fq 'up -d --no-build --no-deps --force-recreate otel-collector' "$success_log"

printf '%s\n' 'OTel installer guard fixtures passed.'
