#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/deploy/install-otel-health-probe.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

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
    "OTEL_QUIESCE_PROOF",
    "OTEL_ROLLBACK_TIMEOUT_SECONDS",
)
missing = [needle for needle in required if needle not in source]
if missing:
    raise SystemExit(f"installer contract is missing: {', '.join(missing)}")
if "timeout --foreground" in source:
    raise SystemExit("installer uses a timeout mode that leaves grandchildren running")
if source.count("install_mutated=true") != 1:
    raise SystemExit("installer mutation marker is not single and explicit")
if source.index("install_mutated=true") > source.index("bounded_run 'Collector image build'"):
    raise SystemExit("image build is not covered by compensation")
PY

fake_bin="$test_root/bin"
state_dir="$test_root/state"
mkdir -p -- "$fake_bin" "$state_dir"
env_file="$test_root/.env"
cat >"$env_file" <<'ENV'
MLFLOW_EXPERIMENT_ID=0
LAMINAR_PROJECT_API_KEY=fixture-key
ENV

collector_config="$repo_root/deploy/otel-collector.yaml"
expected_mount_source="$(readlink -f "$collector_config")"
cat >"$state_dir/inspect.json" <<JSON
[{"Id":"fixture-container-id","Name":"/ai-agent-observability-otel-collector","Image":"sha256:fixture-active","Created":"2026-09-08T00:00:00Z","Config":{"Entrypoint":[],"Cmd":["--feature-gates=+extension.healthcheck.useComponentStatus","--config=/etc/otelcol-contrib/config.yaml"],"ExposedPorts":{"4317/tcp":{},"4318/tcp":{}},"Env":["MLFLOW_EXPERIMENT_ID=0","LAMINAR_PROJECT_API_KEY=fixture-key"],"Healthcheck":{"Test":["CMD","/usr/local/bin/otel-health-probe"]},"Labels":{"com.docker.compose.project":"ai-agent-observability","com.docker.compose.service":"otel-collector"},"ReadonlyRootfs":true,"User":"","WorkingDir":"/"},"HostConfig":{"PortBindings":{"4317/tcp":[{"HostIp":"127.0.0.1","HostPort":"14317"}],"4318/tcp":[{"HostIp":"127.0.0.1","HostPort":"14318"}]},"PublishAllPorts":false,"NetworkMode":"ai-agent-observability_default","ExtraHosts":[],"Devices":[],"DeviceRequests":[],"BlkioWeight":0,"CpuCount":0,"CpuPercent":0,"CpuPeriod":0,"CpuQuota":0,"CpuRealtimePeriod":0,"CpuRealtimeRuntime":0,"CpuShares":0,"CpusetCpus":"","CpusetMems":"","NanoCpus":0,"Memory":0,"MemoryReservation":0,"MemorySwap":0,"MemorySwappiness":0,"OomKillDisable":false,"PidsLimit":0,"Ulimits":[],"ReadonlyRootfs":true,"SecurityOpt":["no-new-privileges:true"],"CapAdd":[],"CapDrop":[],"Privileged":false,"Tmpfs":{"/tmp":"rw"},"RestartPolicy":{"Name":"unless-stopped"}},"NetworkSettings":{"Networks":{"ai-agent-observability_default":{"Aliases":["otel-collector","ai-agent-observability-otel-collector"]}}},"Mounts":[{"Type":"bind","Source":"$expected_mount_source","Destination":"/etc/otelcol-contrib/config.yaml","Mode":"ro","RW":false}],"State":{"Health":{"Status":"healthy","Log":[]}}}]
JSON

cat >"$fake_bin/podman" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

log_file="${FAKE_LOG:?}"
state_dir="${FAKE_STATE_DIR:?}"
printf '%s\n' "$*" >>"$log_file"

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
    if [[ "${FAKE_BUILD_FAIL:-}" == yes ]]; then
      printf '%s\n' 'fixture build failure' >&2
      exit 42
    fi
    : >"$state_dir/built"
    exit 0
  fi
  if [[ " $* " == *" up "* ]]; then
    : >"$state_dir/recreated"
    exit 0
  fi
  exit 0
fi

if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
  if [[ -e "$state_dir/built" ]]; then
    printf '%s\n' 'sha256:fixture-built'
  else
    printf '%s\n' 'sha256:fixture-active'
  fi
  exit 0
fi

if [[ "${1:-}" == image && "${2:-}" == tag ]]; then
  : >"$state_dir/retagged"
  exit 0
fi

if [[ "${1:-}" == inspect ]]; then
  if [[ " $* " == *" --format "* ]]; then
    format="${3:-}"
    case "$format" in
      *'.Image'*)
        printf '%s\n' 'sha256:fixture-active'
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
        printf '%s\n' healthy
        ;;
      *)
        printf '%s\n' 'unsupported fixture inspect format' >&2
        exit 1
        ;;
    esac
  else
    if [[ -e "$state_dir/built" ]]; then
      sed 's/sha256:fixture-active/sha256:fixture-built/g' "${FAKE_STATE_DIR:?}/inspect.json"
    else
      cat "${FAKE_STATE_DIR:?}/inspect.json"
    fi
  fi
  exit 0
fi

if [[ "${1:-}" == cp ]]; then
  destination="${@: -1}"
  cp "${FAKE_CONFIG:?}" "$destination"
  exit 0
fi

printf 'unsupported fixture podman invocation: %s\n' "$*" >&2
exit 1
FAKE
chmod +x "$fake_bin/podman"

log_file="$test_root/check.log"
: >"$log_file"
common_env=(
  OTEL_ENGINE=podman
  OTEL_COMPOSE_PROJECT=ai-agent-observability
  OTEL_CONTAINER_NAME=ai-agent-observability-otel-collector
  OTEL_ENV_FILE="$env_file"
  OTEL_BACKUP_ROOT="$test_root/check-backups"
  OTEL_EXPECTED_GIT_HEAD="$(git -C "$repo_root" rev-parse HEAD)"
  OTEL_EXPECTED_PROBE_SHA256="$(sha256sum "$repo_root/deploy/otel-health-probe.c" | awk '{print $1}')"
  OTEL_EXPECTED_CONFIG_SHA256="$(sha256sum "$collector_config" | awk '{print $1}')"
  OTEL_EXPECTED_COMPOSE_SHA256="$(sha256sum "$repo_root/deploy/compose.yaml" | awk '{print $1}')"
  OTEL_EXPECTED_DOCKERFILE_SHA256="$(sha256sum "$repo_root/deploy/Dockerfile.otel" | awk '{print $1}')"
  OTEL_EXPECTED_ACTIVE_IMAGE_ID=sha256:fixture-active
  OTEL_EXPECTED_TRACE_EXPORTERS=otlp_http/mlflow,otlp_http/laminar
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

proof="$test_root/quiescence.json"
old_stamp="$(date -u -d '6 seconds ago' '+%Y-%m-%dT%H:%M:%SZ')"
new_stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat >"$proof" <<JSON
{"schema":"otel-quiescence-proof-v1","verified":true,"approved":true,"project":"ai-agent-observability","service":"otel-collector","container":"ai-agent-observability-otel-collector","container_id":"fixture-container-id","observed_at_utc":"$new_stamp","observations":[{"source":"live-collector-metrics+producer-drain","active_requests":0,"queue_depth":0,"producers_drained":true,"observed_at_utc":"$old_stamp"},{"source":"live-collector-metrics+producer-drain","active_requests":0,"queue_depth":0,"producers_drained":true,"observed_at_utc":"$new_stamp"}]}
JSON

install_log="$test_root/install.log"
: >"$install_log"
install_env=(
  "${common_env[@]}"
  OTEL_BACKUP_ROOT="$test_root/install-backups"
  OTEL_HEALTH_PROBE_INSTALL_APPROVED=true
  OTEL_QUIESCE_APPROVED=true
  OTEL_QUIESCE_PROOF="$proof"
  OTEL_EXPECTED_BUILT_IMAGE_ID=sha256:fixture-built
  OTEL_BUILD_TIMEOUT_SECONDS=10
  OTEL_RECREATE_TIMEOUT_SECONDS=10
  OTEL_INSPECT_TIMEOUT_SECONDS=2
  OTEL_INSTALL_TIMEOUT_SECONDS=30
  OTEL_ROLLBACK_TIMEOUT_SECONDS=30
  OTEL_READY_TIMEOUT_SECONDS=10
  OTEL_MAX_CAPTURE_BYTES=65536
)

status=0
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
grep -Fq 'up -d --no-build --no-deps --force-recreate otel-collector' "$install_log"
[[ -e "$state_dir/retagged" && -e "$state_dir/recreated" ]] || exit 1
if grep -Fq 'rollback UNKNOWN' "$test_root/install.err"; then
  printf '%s\n' 'fixture build failure did not complete verified rollback' >&2
  exit 1
fi

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
  OTEL_INSTALL_TIMEOUT_SECONDS=30
  OTEL_ROLLBACK_TIMEOUT_SECONDS=30
  OTEL_READY_TIMEOUT_SECONDS=10
  OTEL_MAX_CAPTURE_BYTES=65536
)
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
