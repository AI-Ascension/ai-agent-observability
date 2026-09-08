#!/usr/bin/env bash
set -Eeuo pipefail

# Guarded owner-side installer for the Collector wrapper image. It is a
# deployment handoff, not part of the runtime image and never runs implicitly.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
compose_file="$script_dir/compose.yaml"
collector_config="$script_dir/otel-collector.yaml"
probe_source="$script_dir/otel-health-probe.c"
dockerfile="$script_dir/Dockerfile.otel"
env_file="${OTEL_ENV_FILE:-$script_dir/.env}"
project_name="${OTEL_COMPOSE_PROJECT:-ai-agent-observability}"
container_name="${OTEL_CONTAINER_NAME:-ai-agent-observability-otel-collector}"
mount_destination="/etc/otelcol-contrib/config.yaml"
probe_path="/usr/local/bin/otel-health-probe"
backup_root="${OTEL_BACKUP_ROOT:-$repo_dir/.otel-health-probe-backups}"
mode="${1:---install}"
build_timeout_seconds="${OTEL_BUILD_TIMEOUT_SECONDS:-900}"
recreate_timeout_seconds="${OTEL_RECREATE_TIMEOUT_SECONDS:-180}"
inspect_timeout_seconds="${OTEL_INSPECT_TIMEOUT_SECONDS:-15}"
ready_timeout_seconds="${OTEL_READY_TIMEOUT_SECONDS:-240}"
install_timeout_seconds="${OTEL_INSTALL_TIMEOUT_SECONDS:-1200}"
rollback_timeout_seconds="${OTEL_ROLLBACK_TIMEOUT_SECONDS:-600}"
max_capture_bytes="${OTEL_MAX_CAPTURE_BYTES:-4194304}"
quiesce_observation_seconds="${OTEL_QUIESCE_OBSERVATION_SECONDS:-5}"
image_tag_mutated=false
runtime_mutation_attempted=false
runtime_mutation_may_have_changed=false
rollback_active=false
backup_dir=""
previous_image_id=""
previous_config_sha256=""
previous_env_sha256=""
previous_full_env_sha256=""
previous_runtime_sha256=""
previous_health=""
image_ref=""
metrics_url=""
install_deadline=0
rollback_deadline=0
runtime_container_id=""
observed_runtime_container_id=""

case "$mode" in
  --check|--install) ;;
  *)
    printf '%s\n' "usage: $0 [--check|--install]" >&2
    exit 64
    ;;
esac

fail() {
  printf 'otel installer: %s\n' "$1" >&2
  exit 1
}

need_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

require_hash() {
  local name="$1"
  local path="$2"
  local expected="${!name:-}"
  local actual

  need_value "$name"
  [[ -f "$path" ]] || fail "missing $path"
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || fail "$path hash does not match $name"
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

remaining_timeout() {
  local requested="$1"
  local remaining=$((install_deadline - SECONDS))
  (( remaining > 0 )) || fail "overall installation timeout of ${install_timeout_seconds}s exceeded"
  (( requested < remaining )) && printf '%s\n' "$requested" || printf '%s\n' "$remaining"
}

rollback_remaining_timeout() {
  local requested="$1"
  local remaining=$((rollback_deadline - SECONDS))
  (( remaining > 0 )) || return 1
  (( requested < remaining )) && printf '%s\n' "$requested" || printf '%s\n' "$remaining"
}

operation_timeout() {
  if [[ "$rollback_active" == true ]]; then
    rollback_remaining_timeout "$1"
  else
    remaining_timeout "$1"
  fi
}

# Keep engine operations bounded and distinguish timeout from a normal command
# failure. Stdout and stderr are capped separately; only stdout is returned so
# engine diagnostics cannot contaminate identity values or echo secrets.
bounded_capture() {
  local label="$1"
  local requested="$2"
  shift 2
  local output error status seconds file_limit bytes error_bytes
  output="$(mktemp)"
  error="$(mktemp)"
  if ! seconds="$(operation_timeout "$requested")"; then
    rm -f -- "$output" "$error"
    printf 'otel installer: %s exceeded its aggregate timeout budget\n' "$label" >&2
    return 124
  fi
  file_limit=$(( (max_capture_bytes + 511) / 512 ))
  # No --foreground means timeout owns a process group and can terminate
  # grandchildren. ulimit caps inherited stdout and stderr before either temp
  # file grows.
  if timeout --kill-after=5s "${seconds}s" \
      bash -c 'ulimit -f "$1" || exit 125; shift; exec "$@"' _ "$file_limit" "$@" >"$output" 2>"$error"; then
    bytes="$(wc -c <"$output")"
    error_bytes="$(wc -c <"$error")"
    if (( bytes > max_capture_bytes || error_bytes > max_capture_bytes )); then
      rm -f -- "$output" "$error"
      printf 'otel installer: %s exceeded the %s-byte capture limit\n' "$label" "$max_capture_bytes" >&2
      return 125
    fi
    cat -- "$output"
    rm -f -- "$output" "$error"
    return 0
  else
    status=$?
  fi
  rm -f -- "$output" "$error"
  if [[ "$status" == 124 || "$status" == 137 ]]; then
    printf 'otel installer: %s timed out after %ss\n' "$label" "$seconds" >&2
    return 124
  fi
  if [[ "$status" == 125 || "$status" == 153 ]]; then
    printf 'otel installer: %s exceeded the %s-byte capture limit\n' "$label" "$max_capture_bytes" >&2
    return 125
  fi
  printf 'otel installer: %s failed (exit %s)\n' "$label" "$status" >&2
  return "$status"
}

bounded_run() {
  local label="$1"
  local requested="$2"
  shift 2
  local status
  if bounded_capture "$label" "$requested" "$@" >/dev/null; then
    return 0
  else
    status=$?
  fi
  return "$status"
}

case "${OTEL_ENGINE:-podman}" in
  podman)
    command -v podman >/dev/null 2>&1 || fail 'podman is required'
    engine=(podman)
    compose=(podman compose --env-file "$env_file")
    ;;
  docker)
    command -v docker >/dev/null 2>&1 || fail 'docker is required'
    engine=(docker)
    compose=(docker compose --env-file "$env_file")
    ;;
  *)
    fail 'OTEL_ENGINE must be podman or docker'
    ;;
esac

command -v git >/dev/null 2>&1 || fail 'git is required'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
command -v timeout >/dev/null 2>&1 || fail 'timeout is required'
command -v awk >/dev/null 2>&1 || fail 'awk is required'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
command -v readlink >/dev/null 2>&1 || fail 'readlink is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$compose_file" && -f "$collector_config" && -f "$probe_source" && -f "$dockerfile" ]] || \
  fail 'deployment files are incomplete'
[[ -f "$env_file" ]] || fail "missing environment file: $env_file"
require_positive_integer OTEL_BUILD_TIMEOUT_SECONDS "$build_timeout_seconds"
require_positive_integer OTEL_RECREATE_TIMEOUT_SECONDS "$recreate_timeout_seconds"
require_positive_integer OTEL_INSPECT_TIMEOUT_SECONDS "$inspect_timeout_seconds"
require_positive_integer OTEL_READY_TIMEOUT_SECONDS "$ready_timeout_seconds"
require_positive_integer OTEL_INSTALL_TIMEOUT_SECONDS "$install_timeout_seconds"
require_positive_integer OTEL_ROLLBACK_TIMEOUT_SECONDS "$rollback_timeout_seconds"
require_positive_integer OTEL_MAX_CAPTURE_BYTES "$max_capture_bytes"
require_positive_integer OTEL_QUIESCE_OBSERVATION_SECONDS "$quiesce_observation_seconds"
(( max_capture_bytes <= 16777216 )) || fail 'OTEL_MAX_CAPTURE_BYTES exceeds 16777216 bytes'
(( max_capture_bytes >= 512 )) || fail 'OTEL_MAX_CAPTURE_BYTES is too small'
(( quiesce_observation_seconds >= 5 && quiesce_observation_seconds <= 120 )) || \
  fail 'OTEL_QUIESCE_OBSERVATION_SECONDS must be between 5 and 120 seconds'
# The aggregate deadline begins before source, runtime, and backup preflight.
# Every later bounded operation uses the remaining budget as its upper bound.
install_deadline=$((SECONDS + install_timeout_seconds))

need_value OTEL_EXPECTED_GIT_HEAD
actual_head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual_head" == "$OTEL_EXPECTED_GIT_HEAD" ]] || fail 'source HEAD does not match OTEL_EXPECTED_GIT_HEAD'
build_input_status="$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all -- \
  deploy/Dockerfile.otel deploy/otel-health-probe.c 2>/dev/null || true)"
[[ -z "$build_input_status" ]] || fail 'Collector build inputs are dirty'
require_hash OTEL_EXPECTED_PROBE_SHA256 "$probe_source"
require_hash OTEL_EXPECTED_CONFIG_SHA256 "$collector_config"
require_hash OTEL_EXPECTED_COMPOSE_SHA256 "$compose_file"
require_hash OTEL_EXPECTED_DOCKERFILE_SHA256 "$dockerfile"

# Static guards cover the runtime contract before a mutable engine is touched.
grep -Fq 'service:' "$collector_config" || fail 'collector config has no service section'
grep -Fq 'pipelines:' "$collector_config" || fail 'collector config has no pipelines section'
grep -Fq 'endpoint: 127.0.0.1:13133' "$collector_config" || fail 'collector health endpoint moved off loopback'
grep -Fq 'health_check:' "$collector_config" || fail 'collector health extension is absent'
grep -Fq 'component_health:' "$collector_config" || fail 'component health status is absent'
grep -Fq 'sending_queue:' "$collector_config" || \
  fail 'Collector queue metrics are not configured for the quiescence observer'
grep -Fq 'without_type_suffix: true' "$collector_config" || \
  fail 'Collector Prometheus metrics naming is not pinned for the quiescence observer'
grep -Fq 'OTEL_METRICS_PORT' "$compose_file" || fail 'Collector metrics port is not configured'
grep -Fq 'extension.healthcheck.useComponentStatus' "$compose_file" || fail 'component status feature gate is absent'
grep -Fq '/usr/local/bin/otel-health-probe' "$compose_file" || fail 'native probe healthcheck is absent'
grep -Fq './otel-collector.yaml:/etc/otelcol-contrib/config.yaml:ro' "$compose_file" || \
  fail 'collector config mount is not read-only'
if grep -Eq 'published:.*13133|:13133:' "$compose_file"; then
  fail 'collector health endpoint is published on the host'
fi

# The expected exporter set is an explicit owner input. Parse only the active
# service.pipelines.traces.exporters list; declarations elsewhere are not
# evidence that an exporter is enabled.
active_exporters_text="$(python3 - "$collector_config" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
state = "root"
service_indent = pipelines_indent = traces_indent = exporters_indent = -1
found = False
values = []

def scalar(value):
    value = value.strip()
    if not value:
        raise ValueError("empty exporter")
    if value[0] in "'\"" and value[-1:] == value[0]:
        value = value[1:-1]
    if not value or any(ch.isspace() for ch in value):
        raise ValueError("invalid exporter")
    return value

for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    indent = len(raw) - len(raw.lstrip(" "))
    text = raw.strip()
    if state == "root":
        if indent == 0 and text == "service:":
            state, service_indent = "service", indent
        continue
    if state == "service":
        if indent <= service_indent:
            continue
        if text == "pipelines:":
            state, pipelines_indent = "pipelines", indent
        continue
    if state == "pipelines":
        if indent <= pipelines_indent:
            continue
        if text == "traces:":
            state, traces_indent = "traces", indent
        continue
    if state == "traces":
        if indent <= traces_indent:
            continue
        if text.startswith("exporters:"):
            rhs = text[len("exporters:"):].strip()
            found = True
            exporters_indent = indent
            if rhs:
                if not (rhs.startswith("[") and rhs.endswith("]")):
                    raise ValueError("invalid inline exporter list")
                values = [scalar(part) for part in rhs[1:-1].split(",") if part.strip()]
                if not values or len(values) != len(set(values)):
                    raise ValueError("empty or duplicate exporter")
                break
            state = "list"
        continue
    if state == "list":
        if indent <= exporters_indent:
            break
        if not text.startswith("-"):
            raise ValueError("invalid exporter list item")
        values.append(scalar(text[1:]))

if not found or not values or len(values) != len(set(values)):
    raise ValueError("missing or duplicate active exporters")
sys.stdout.write("\n".join(values) + "\n")
PY
)" || fail 'unable to parse active traces exporters'

need_value OTEL_EXPECTED_TRACE_EXPORTERS
IFS=',' read -r -a expected_exporters <<<"$OTEL_EXPECTED_TRACE_EXPORTERS"
for exporter in "${expected_exporters[@]}"; do
  exporter="${exporter#"${exporter%%[![:space:]]*}"}"
  exporter="${exporter%"${exporter##*[![:space:]]}"}"
  [[ -n "$exporter" ]] || fail 'OTEL_EXPECTED_TRACE_EXPORTERS contains an empty entry'
done
expected_canonical="$(printf '%s\n' "${expected_exporters[@]}" | LC_ALL=C sort)"
active_canonical="$(printf '%s\n' "$active_exporters_text" | LC_ALL=C sort)"
[[ "$expected_canonical" == "$active_canonical" ]] || \
  fail 'active traces exporter set does not match OTEL_EXPECTED_TRACE_EXPORTERS'

# Resolve the service image from the rendered model so an override cannot make
# image verification inspect a tag different from the one Compose builds.
bounded_run 'Compose model validation' "$inspect_timeout_seconds" \
  "${compose[@]}" -p "$project_name" -f "$compose_file" config --quiet
rendered_compose="$(bounded_capture 'Compose model rendering' "$inspect_timeout_seconds" \
  "${compose[@]}" -p "$project_name" -f "$compose_file" config)"
image_ref="$(awk '
  /^  otel-collector:$/ { in_service = 1; next }
  in_service && /^[^[:space:]]/ { in_service = 0 }
  in_service && /^[[:space:]]+image:[[:space:]]*/ {
    value = $0
    sub(/^[[:space:]]+image:[[:space:]]*/, "", value)
    count++
    print value
  }
  END { if (count != 1) exit 1 }
' <<<"$rendered_compose")" || fail 'rendered Compose has no unique otel-collector image'
if [[ -n "${OTEL_IMAGE_REF:-}" && "$OTEL_IMAGE_REF" != "$image_ref" ]]; then
  fail 'OTEL_IMAGE_REF does not match the rendered Compose service image'
fi

dotenv_value() {
  local key="$1"
  local value
  value="$(awk -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, key "=") == 1) {
        count++
        value = substr(line, length(key) + 2)
      }
    }
    END { if (count != 1) exit 2; print value }
  ' "$env_file")" || fail "environment key $key is missing or duplicated"
  if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] ||
     [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

expected_env_names=(MLFLOW_EXPERIMENT_ID LAMINAR_PROJECT_API_KEY)
declare -A expected_env
for env_name in "${expected_env_names[@]}"; do
  expected_env["$env_name"]="$(dotenv_value "$env_name")"
done

verify_env_text() {
  local env_text="$1"
  local env_name
  for env_name in "${expected_env_names[@]}"; do
    printf '%s\n' "$env_text" | awk -F= -v key="$env_name" -v expected="${expected_env[$env_name]}" \
      '$1 == key { count++; if ($0 != key "=" expected) bad=1 }
       END { exit (count == 1 && !bad) ? 0 : 1 }' || return 1
  done
}

env_identity() {
  local env_text="$1"
  local env_name
  for env_name in "${expected_env_names[@]}"; do
    printf '%s\n' "$env_text" | awk -F= -v key="$env_name" -v expected="${expected_env[$env_name]}" \
      '$1 == key && $0 == key "=" expected { print $0; found++ }
       END { if (found != 1) exit 1 }' || return 1
  done | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

expected_env_lines="$(for env_name in "${expected_env_names[@]}"; do
  printf '%s=%s\n' "$env_name" "${expected_env[$env_name]}"
done | LC_ALL=C sort)"
expected_env_sha256="$(printf '%s\n' "$expected_env_lines" | sha256sum | awk '{print $1}')"

metrics_bind_address="$(dotenv_value BIND_ADDRESS)"
metrics_port="$(dotenv_value OTEL_METRICS_PORT)"
[[ "$metrics_bind_address" == 127.0.0.1 ]] || \
  fail 'BIND_ADDRESS must remain 127.0.0.1 while the Collector metrics observer is enabled'
require_positive_integer OTEL_METRICS_PORT "$metrics_port"
metrics_url="${OTEL_METRICS_URL:-http://${metrics_bind_address}:${metrics_port}/metrics}"
[[ "$metrics_url" == http://* ]] || fail 'OTEL_METRICS_URL must use plain HTTP on the protected loopback endpoint'

active_image_id="$(bounded_capture 'active Collector image inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{.Image}}' "$container_name")"
need_value OTEL_EXPECTED_ACTIVE_IMAGE_ID
[[ "$active_image_id" == "$OTEL_EXPECTED_ACTIVE_IMAGE_ID" ]] || \
  fail 'active Collector image identity does not match OTEL_EXPECTED_ACTIVE_IMAGE_ID'
active_labels="$(bounded_capture 'active Collector label inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{printf "%s\t%s" (index .Config.Labels "com.docker.compose.project") (index .Config.Labels "com.docker.compose.service")}}' "$container_name")"
[[ "$active_labels" == "$project_name"$'\t'otel-collector ]] || \
  fail 'active Collector Compose project or service identity does not match the reviewed target'
container_inspect_raw="$(bounded_capture 'active Collector container inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect "$container_name")"
container_inspect="$(python3 -c '
import json
import sys

rows = json.load(sys.stdin)
safe = []
for row in rows:
    config = row.get("Config") or {}
    safe.append({
        "Id": row.get("Id"),
        "Name": row.get("Name"),
        "Image": row.get("Image"),
        "Created": row.get("Created"),
        "State": row.get("State"),
        "Mounts": row.get("Mounts"),
        "NetworkSettings": row.get("NetworkSettings"),
        "Config": {
            "Healthcheck": config.get("Healthcheck"),
            "Labels": config.get("Labels"),
            "ReadonlyRootfs": config.get("ReadonlyRootfs"),
            "User": config.get("User"),
            "WorkingDir": config.get("WorkingDir"),
        },
    })
json.dump(safe, sys.stdout, sort_keys=True)
sys.stdout.write("\n")
' <<<"$container_inspect_raw")" || fail 'active Collector inspect could not be sanitized'
active_mounts="$(bounded_capture 'active Collector mount inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%t\t%s\n" .Type .Source .Destination .RW .Mode}}{{end}}' "$container_name")"
expected_mount_source="$(readlink -f "$collector_config")"
mount_matches=0
while IFS=$'\t' read -r mount_type mount_source mount_target mount_rw mount_mode; do
  [[ -n "${mount_target:-}" ]] || continue
  if [[ "$mount_target" == "$mount_destination" ]]; then
    ((mount_matches += 1))
    [[ "$mount_type" == bind && "$mount_source" == "$expected_mount_source" && \
       "$mount_rw" == false ]] || fail 'active Collector config mount source, destination, or RO mode is wrong'
  fi
done <<<"$active_mounts"
[[ "$mount_matches" == 1 ]] || fail 'active Collector config mount is unavailable or duplicated'

mounted_tmp="$(mktemp -d)"
bounded_run 'active mounted config copy' "$inspect_timeout_seconds" \
  "${engine[@]}" cp "$container_name:$mount_destination" "$mounted_tmp/config.yaml"
mounted_config_sha256="$(sha256_file "$mounted_tmp/config.yaml")"
expected_config_sha256="$(sha256_file "$collector_config")"
rm -rf -- "$mounted_tmp"
[[ "$mounted_config_sha256" == "$expected_config_sha256" ]] || \
  fail 'active mounted Collector config hash does not match the reviewed config'
active_healthcheck="$(bounded_capture 'active Collector healthcheck inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{json .Config.Healthcheck.Test}}' "$container_name")"
grep -Fq "$probe_path" <<<"$active_healthcheck" || fail 'active native probe is unavailable'
active_env_text="$(bounded_capture 'active container environment inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name")"
verify_env_text "$active_env_text" || fail 'active Collector environment does not match the intended .env'
active_env_sha256="$(env_identity "$active_env_text")" || fail 'active Collector environment identity is unavailable'
[[ "$active_env_sha256" == "$expected_env_sha256" ]] || fail 'active Collector environment identity mismatch'
env_identity_all() {
  local env_text="$1"
  # Keep the complete container environment comparison secret-safe: only the
  # digest is retained or reported, never the values themselves.
  printf '%s\n' "$env_text" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}
active_full_env_sha256="$(env_identity_all "$active_env_text")"

runtime_identity() {
  local inspect_json="$1"
  # Keep the complete runtime contract secret-safe and stable across a
  # recreation: dynamic IP addresses are excluded, while every requested
  # command, port, network, device, and resource setting is compared.
  jq -cS '
    .[0] as $c |
    {
      config: {
        entrypoint: ($c.Config.Entrypoint // []),
        cmd: ($c.Config.Cmd // []),
        exposed_ports: (($c.Config.ExposedPorts // {}) | to_entries | sort_by(.key)),
        user: ($c.Config.User // ""),
        working_dir: ($c.Config.WorkingDir // ""),
        stop_signal: ($c.Config.StopSignal // "")
      },
      host: {
        port_bindings: (($c.HostConfig.PortBindings // {}) | to_entries | sort_by(.key) |
          map({port:.key, bindings:(.value // [] | sort_by(.HostIp,.HostPort) |
            map({host_ip:(.HostIp // ""), host_port:(.HostPort // "")}))})),
        publish_all_ports: ($c.HostConfig.PublishAllPorts // false),
        network_mode: ($c.HostConfig.NetworkMode // ""),
        extra_hosts: (($c.HostConfig.ExtraHosts // []) | sort),
        devices: (($c.HostConfig.Devices // []) | map({host:(.PathOnHost // ""),container:(.PathInContainer // ""),permissions:(.CgroupPermissions // "")}) | sort_by(.host,.container,.permissions)),
        device_requests: (($c.HostConfig.DeviceRequests // []) | map({driver:(.Driver // ""),count:(.Count // 0),device_ids:(.DeviceIDs // [] | sort),capabilities:(.Capabilities // [] | map(sort) | sort)}) | sort_by(.driver,.count,.device_ids)),
        resources: {
          blkio_weight: ($c.HostConfig.BlkioWeight // 0),
          cpu_count: ($c.HostConfig.CpuCount // 0),
          cpu_percent: ($c.HostConfig.CpuPercent // 0),
          cpu_period: ($c.HostConfig.CpuPeriod // 0),
          cpu_quota: ($c.HostConfig.CpuQuota // 0),
          cpu_realtime_period: ($c.HostConfig.CpuRealtimePeriod // 0),
          cpu_realtime_runtime: ($c.HostConfig.CpuRealtimeRuntime // 0),
          cpu_shares: ($c.HostConfig.CpuShares // 0),
          cpuset_cpus: ($c.HostConfig.CpusetCpus // ""),
          cpuset_mems: ($c.HostConfig.CpusetMems // ""),
          nano_cpus: ($c.HostConfig.NanoCpus // 0),
          memory: ($c.HostConfig.Memory // 0),
          memory_reservation: ($c.HostConfig.MemoryReservation // 0),
          memory_swap: ($c.HostConfig.MemorySwap // 0),
          memory_swappiness: ($c.HostConfig.MemorySwappiness // 0),
          oom_kill_disable: ($c.HostConfig.OomKillDisable // false),
          pids_limit: ($c.HostConfig.PidsLimit // 0),
          ulimits: (($c.HostConfig.Ulimits // []) | map({name:(.Name // ""),soft:(.Soft // 0),hard:(.Hard // 0)}) | sort_by(.name))
        },
        readonly_rootfs: ($c.HostConfig.ReadonlyRootfs // false),
        security_opt: (($c.HostConfig.SecurityOpt // []) | sort),
        cap_add: (($c.HostConfig.CapAdd // []) | sort),
        cap_drop: (($c.HostConfig.CapDrop // []) | sort),
        privileged: ($c.HostConfig.Privileged // false),
        tmpfs: (($c.HostConfig.Tmpfs // {}) | to_entries | sort_by(.key)),
        restart_policy: ($c.HostConfig.RestartPolicy // {})
      },
      networks: (($c.NetworkSettings.Networks // {}) | to_entries |
        map({name:.key, aliases:(.value.Aliases // [] | sort)}) | sort_by(.name)),
      mounts: (($c.Mounts // []) | map({type:(.Type // ""),source:(.Source // ""),destination:(.Destination // ""),mode:(.Mode // ""),rw:(.RW // false)}) | sort_by(.destination,.source,.type))
    }
  ' <<<"$inspect_json"
}

active_container_id="$(jq -r '.[0].Id // ""' <<<"$container_inspect_raw")"
[[ -n "$active_container_id" ]] || fail 'active Collector container identity is unavailable'
active_state_status="$(jq -r '.[0].State.Status // "missing"' <<<"$container_inspect_raw")"
[[ "$active_state_status" == running ]] || \
  fail "active Collector is not running (state=$active_state_status)"
healthcheck_contract_matches() {
  local inspect_json="$1"
  jq -e --arg probe "$probe_path" '
    .[0].Config.Healthcheck as $health |
    ($health | type) == "object" and
    ($health.Test | type) == "array" and
    ($health.Test | length) >= 2 and
    ($health.Test[0] == "CMD" or $health.Test[0] == "CMD-SHELL") and
    ($health.Test | any(. == $probe)) and
    ($health.Interval // 0) != 0 and
    ($health.Timeout // 0) != 0 and
    ($health.Retries // 0) > 0
  ' <<<"$inspect_json" >/dev/null
}
healthcheck_contract_matches "$container_inspect_raw" || \
  fail 'active Collector healthcheck contract is missing or does not invoke the native probe'
active_runtime_sha256="$(runtime_identity "$container_inspect_raw" | sha256sum | awk '{print $1}')"
[[ "$active_runtime_sha256" =~ ^[0-9a-f]{64}$ ]] || fail 'active Collector runtime identity is unavailable'

assert_active_container_unchanged() {
  local current_json current_id current_image
  current_json="$(bounded_capture 'active Collector identity recheck' "$inspect_timeout_seconds" \
    "${engine[@]}" inspect "$container_name")" || return 1
  current_id="$(jq -r '.[0].Id // ""' <<<"$current_json")" || return 1
  current_image="$(jq -r '.[0].Image // ""' <<<"$current_json")" || return 1
  [[ "$current_id" == "$active_container_id" && "$current_image" == "$active_image_id" ]] || return 1
}

verify_quiescence_approval() {
  local proof="$1"
  local expected_id="$2"
  [[ -f "$proof" ]] || fail 'OTEL_QUIESCE_PROOF must name a fresh approval file'
  python3 - "$proof" "$project_name" "$container_name" "$expected_id" \
    "${OTEL_QUIESCE_MAX_AGE_SECONDS:-120}" <<'PY'
import datetime as dt
import json
import sys
from pathlib import Path

path, project, container, expected_id, max_age_text = sys.argv[1:]
try:
    max_age = int(max_age_text)
except ValueError:
    raise SystemExit("OTEL_QUIESCE_MAX_AGE_SECONDS must be an integer")
if max_age < 5 or max_age > 3600:
    raise SystemExit("OTEL_QUIESCE_MAX_AGE_SECONDS is outside 5..3600")
try:
    proof = json.loads(Path(path).read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"quiescence approval is not valid JSON: {exc}")
if proof.get("schema") != "otel-quiescence-approval-v1":
    raise SystemExit("quiescence approval schema is invalid")
if proof.get("approved") is not True:
    raise SystemExit("quiescence approval is not approved")
if proof.get("project") != project or proof.get("service") != "otel-collector":
    raise SystemExit("quiescence approval target does not match the reviewed service")
if proof.get("container") != container or proof.get("container_id") != expected_id:
    raise SystemExit("quiescence approval container identity does not match the active container")
try:
    stamp = dt.datetime.fromisoformat(str(proof["approved_at_utc"]).replace("Z", "+00:00"))
except Exception as exc:
    raise SystemExit(f"quiescence approval timestamp is invalid: {exc}")
if stamp.tzinfo is None:
    raise SystemExit("quiescence approval timestamp has no timezone")
age = (dt.datetime.now(dt.timezone.utc) - stamp.astimezone(dt.timezone.utc)).total_seconds()
if age < -5 or age > max_age:
    raise SystemExit("quiescence approval is stale or from the future")
PY
}

# The approval file records operator intent only. Quiescence is established by
# this read-only observer against the running Collector's Prometheus endpoint:
# every exporter queue and in-flight request must be zero, and the accepted
# span counter must remain unchanged over the complete bounded interval.
observe_live_quiescence() {
  local label="$1"
  local requested="$2"
  # The requested interval is the observation window itself. Allow a bounded
  # margin for the initial/final HTTP samples so the outer timeout cannot kill
  # a valid five-second observation at its deadline.
  bounded_capture "$label" "$((requested + 5))" python3 - "$metrics_url" \
    "$quiesce_observation_seconds" <<'PY'
import json
import math
import re
import sys
import time
import urllib.error
import urllib.request

url, duration_text = sys.argv[1:]
try:
    duration = int(duration_text)
except ValueError:
    raise SystemExit("OTEL_QUIESCE_OBSERVATION_SECONDS must be an integer")
if duration < 5 or duration > 120:
    raise SystemExit("OTEL_QUIESCE_OBSERVATION_SECONDS is outside 5..120")

sample_re = re.compile(
    r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s+([-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?|NaN|\+Inf|-Inf)(?:\s+\S+)?$"
)
label_re = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')

def parse_labels(text):
    labels = {}
    if not text:
        return labels
    position = 0
    for match in label_re.finditer(text):
        if match.start() != position and text[position:match.start()].strip().strip(","):
            raise ValueError("invalid Prometheus labels")
        labels[match.group(1)] = bytes(match.group(2), "utf-8").decode("unicode_escape")
        position = match.end()
    if text[position:].strip().strip(","):
        raise ValueError("invalid Prometheus labels")
    return labels

def fetch():
    request = urllib.request.Request(url, headers={"Accept": "text/plain; version=0.0.4"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status != 200:
                raise RuntimeError(f"metrics endpoint returned HTTP {response.status}")
            body = response.read(1024 * 1024 + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"live Collector metrics endpoint unavailable: {exc}") from exc
    if len(body) > 1024 * 1024:
        raise RuntimeError("live Collector metrics response exceeded 1048576 bytes")
    queues = []
    in_flight = []
    accepted = []
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"live Collector metrics are not UTF-8: {exc}") from exc
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        match = sample_re.match(line)
        if not match:
            continue
        name, raw_labels, raw_value = match.groups()
        try:
            labels = parse_labels(raw_labels)
            value = float(raw_value)
        except (ValueError, OverflowError) as exc:
            raise RuntimeError(f"invalid live Collector metric sample: {exc}") from exc
        if not math.isfinite(value):
            raise RuntimeError("live Collector metric is not finite")
        if name == "otelcol_exporter_queue_size":
            queues.append((labels, value))
        elif name == "otelcol_exporter_in_flight_requests":
            in_flight.append((labels, value))
        elif name == "otelcol_receiver_accepted_spans":
            accepted.append((labels, value))
    if not queues:
        raise RuntimeError("live Collector queue metric is unavailable")
    if not in_flight:
        raise RuntimeError("live Collector in-flight request metric is unavailable")
    if not accepted:
        raise RuntimeError("live Collector accepted-span metric is unavailable")
    if any(value != 0 for _, value in queues):
        raise RuntimeError("live Collector exporter queue is not empty")
    if any(value != 0 for _, value in in_flight):
        raise RuntimeError("live Collector exporter has in-flight requests")
    return {
        "queue_depth": int(sum(value for _, value in queues)),
        "in_flight_requests": int(sum(value for _, value in in_flight)),
        "accepted_spans": sum(value for _, value in accepted),
        "queue_series": len(queues),
        "accepted_series": len(accepted),
    }

started = time.monotonic()
first = fetch()
last = first
while time.monotonic() - started < duration:
    time.sleep(min(1.0, max(0.0, duration - (time.monotonic() - started))))
    last = fetch()
    if last["accepted_spans"] != first["accepted_spans"]:
        raise SystemExit("live Collector accepted-span counter changed during quiescence observation")
    if last["queue_depth"] != 0 or last["in_flight_requests"] != 0:
        raise SystemExit("live Collector queue or in-flight request state changed during observation")
elapsed = time.monotonic() - started
if elapsed < duration:
    raise SystemExit("live Collector quiescence observation ended before its bounded interval")
if last["accepted_spans"] != first["accepted_spans"]:
    raise SystemExit("live Collector accepted-span counter was not stable")
print(json.dumps({
    "schema": "otel-live-quiescence-v1",
    "observed_seconds": round(elapsed, 3),
    "queue_depth": last["queue_depth"],
    "in_flight_requests": last["in_flight_requests"],
    "accepted_spans": last["accepted_spans"],
    "accepted_spans_stable": True,
    "queue_series": last["queue_series"],
    "accepted_series": last["accepted_series"],
}, sort_keys=True, separators=(",", ":")))
PY
}

active_health="$(bounded_capture 'active Collector health inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name")"
[[ "$active_health" == healthy ]] || fail "active Collector is not healthy (status=$active_health)"

if [[ "$mode" == --check ]]; then
  printf '%s\n' 'OTel source, build inputs, active traces exporters, image, mount, environment, and health guards passed; no mutation performed.'
  exit 0
fi

[[ "${OTEL_HEALTH_PROBE_INSTALL_APPROVED:-}" == true ]] || \
  fail 'set OTEL_HEALTH_PROBE_INSTALL_APPROVED=true for installation'
[[ "${OTEL_QUIESCE_APPROVED:-}" == true ]] || \
  fail 'set OTEL_QUIESCE_APPROVED=true after producers are quiesced'
need_value OTEL_QUIESCE_PROOF
need_value OTEL_EXPECTED_BUILT_IMAGE_ID

command -v flock >/dev/null 2>&1 || fail 'flock is required'
mkdir -p -m 700 "$backup_root"
exec 9>"$backup_root/install.lock"
flock -n 9 || fail 'another OTel installation is already running'

backup_dir="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 700 "$backup_dir"
verify_quiescence_approval "$OTEL_QUIESCE_PROOF" "$active_container_id"
assert_active_container_unchanged || fail 'active Collector identity changed before live quiescence observation'
pre_live_quiescence="$(observe_live_quiescence 'pre-build live Collector quiescence' \
  "$quiesce_observation_seconds")" || fail 'live Collector metrics did not prove pre-build quiescence'
backup_file() {
  local source="$1"
  local destination="$backup_dir/$(basename "$source")"
  local source_hash
  local destination_hash

  cp -p -- "$source" "$destination"
  source_hash="$(sha256_file "$source")"
  destination_hash="$(sha256_file "$destination")"
  [[ "$source_hash" == "$destination_hash" ]] || fail "backup verification failed for $source"
}

backup_sources=("$probe_source" "$collector_config" "$compose_file" "$dockerfile" "$env_file")

backup_file "$probe_source"
backup_file "$collector_config"
backup_file "$compose_file"
backup_file "$dockerfile"
backup_file "$env_file"
chmod 600 "$backup_dir/$(basename "$env_file")"
printf '%s\n' "$container_inspect" >"$backup_dir/container-inspect.json"
printf '%s\n' "$active_image_id" >"$backup_dir/previous-image-id"
printf '%s\n' "$expected_config_sha256" >"$backup_dir/previous-config-sha256"
printf '%s\n' "$active_env_sha256" >"$backup_dir/previous-env-sha256"
printf '%s\n' "$active_full_env_sha256" >"$backup_dir/previous-full-env-sha256"
printf '%s\n' "$active_runtime_sha256" >"$backup_dir/previous-runtime-sha256"
printf '%s\n' "$active_health" >"$backup_dir/previous-health"
printf '%s\n' "$image_ref" >"$backup_dir/previous-image-ref"
printf '%s\n' "$pre_live_quiescence" >"$backup_dir/pre-build-live-quiescence.json"
sha256sum "$backup_dir"/* >"$backup_dir/SHA256SUMS"
chmod 600 "$backup_dir"/container-inspect.json "$backup_dir"/previous-* \
  "$backup_dir"/pre-build-live-quiescence.json "$backup_dir"/SHA256SUMS

# A rollback may restore only files that still have the exact bytes captured at
# preflight. This turns an unrelated edit during a long image build into an
# explicit manual-reconciliation result instead of silently overwriting it.
restore_backups_if_unchanged() {
  local source destination source_hash backup_hash
  for source in "${backup_sources[@]}"; do
    destination="$backup_dir/$(basename "$source")"
    [[ -f "$source" && -f "$destination" ]] || return 1
    source_hash="$(sha256_file "$source")" || return 1
    backup_hash="$(sha256_file "$destination")" || return 1
    [[ "$source_hash" == "$backup_hash" ]] || return 1
  done
  for source in "${backup_sources[@]}"; do
    destination="$backup_dir/$(basename "$source")"
    cp -p -- "$destination" "$source" || return 1
    [[ "$(sha256_file "$source")" == "$(sha256_file "$destination")" ]] || return 1
  done
  chmod 600 "$env_file" || return 1
}

verify_runtime_state() {
  local expected_image="$1"
  local expected_config="$2"
  local expected_env_digest="$3"
  local expected_full_env_digest="$4"
  local expected_health="$5"
  local expected_runtime="$6"
  local expected_container="${7:-}"
  local inspect_json image_id mounts env_text health labels runtime_sha256 cp_seconds state_status
  local mount_count=0
  local temp

  inspect_json="$(bounded_capture 'runtime identity inspect' "$inspect_timeout_seconds" \
    "${engine[@]}" inspect "$container_name")" || return 1
  observed_runtime_container_id="$(jq -r '.[0].Id // ""' <<<"$inspect_json")" || return 1
  [[ -n "$observed_runtime_container_id" ]] || return 1
  if [[ -n "$expected_container" && "$observed_runtime_container_id" != "$expected_container" ]]; then
    return 1
  fi
  image_id="$(jq -r '.[0].Image // ""' <<<"$inspect_json")" || return 1
  [[ "$image_id" == "$expected_image" ]] || return 1
  labels="$(jq -r '.[0].Config.Labels as $l | (($l["com.docker.compose.project"] // "") + "\t" + ($l["com.docker.compose.service"] // ""))' <<<"$inspect_json")" || return 1
  [[ "$labels" == "$project_name"$'\t'otel-collector ]] || return 1
  runtime_sha256="$(runtime_identity "$inspect_json" | sha256sum | awk '{print $1}')" || return 1
  [[ "$runtime_sha256" == "$expected_runtime" ]] || return 1
  mounts="$(jq -r '.[0].Mounts[]? | [.Type,.Source,.Destination,.RW,.Mode] | @tsv' <<<"$inspect_json")" || return 1
  while IFS=$'\t' read -r mount_type mount_source mount_target mount_rw mount_mode; do
    [[ -n "${mount_target:-}" ]] || continue
    if [[ "$mount_target" == "$mount_destination" ]]; then
      ((mount_count += 1))
      [[ "$mount_count" == 1 && "$mount_type" == bind && "$mount_source" == "$expected_mount_source" && \
         "$mount_rw" == false ]] || return 1
    fi
  done <<<"$mounts"
  [[ "$mount_count" == 1 ]] || return 1
  temp="$(mktemp -d)" || return 1
  cp_seconds="$(operation_timeout "$inspect_timeout_seconds")" || {
    rm -rf -- "$temp"
    return 1
  }
  if ! timeout --kill-after=5s "${cp_seconds}s" \
      "${engine[@]}" cp "$container_name:$mount_destination" "$temp/config.yaml" >/dev/null 2>&1; then
    rm -rf -- "$temp"
    return 1
  fi
  if [[ "$(sha256_file "$temp/config.yaml")" != "$expected_config" ]]; then
    rm -rf -- "$temp"
    return 1
  fi
  rm -rf -- "$temp"
  env_text="$(jq -r '.[0].Config.Env[]?' <<<"$inspect_json")" || return 1
  verify_env_text "$env_text" || return 1
  [[ "$(env_identity "$env_text")" == "$expected_env_digest" ]] || return 1
  [[ "$(env_identity_all "$env_text")" == "$expected_full_env_digest" ]] || return 1
  health="$(jq -r '.[0].State.Health.Status // "missing"' <<<"$inspect_json")" || return 1
  [[ "$health" == "$expected_health" ]] || return 1
  state_status="$(jq -r '.[0].State.Status // "missing"' <<<"$inspect_json")" || return 1
  [[ "$state_status" == running ]] || return 1
  healthcheck_contract_matches "$inspect_json" || return 1
  return 0
}

rollback() {
  local original_status="$1"
  local rollback_ok=true
  local restored_image_id phase_status current_id
  local rollback_log=""
  local should_recreate=false

  trap - EXIT RETURN
  set +e
  rollback_active=true
  rollback_deadline=$((SECONDS + rollback_timeout_seconds))
  if [[ -n "$backup_dir" ]]; then
    rollback_log="$backup_dir/rollback.log"
    : >"$rollback_log"
    chmod 600 "$rollback_log"
  fi
  rollback_phase() {
    local label="$1"
    local requested="$2"
    shift 2
    local status seconds

    if ! seconds="$(rollback_remaining_timeout "$requested")"; then
      phase_status='timeout:aggregate'
      [[ -z "$rollback_log" ]] || printf 'phase=%s result=%s\n' "$label" "$phase_status" >>"$rollback_log"
      return 124
    fi
    if timeout --kill-after=5s "${seconds}s" "$@" >/dev/null 2>&1; then
      phase_status=ok
      status=0
    else
      status=$?
      if [[ "$status" == 124 || "$status" == 137 ]]; then
        phase_status="timeout:${status}"
      else
        phase_status="failed:${status}"
      fi
    fi
    [[ -z "$rollback_log" ]] || printf 'phase=%s result=%s\n' "$label" "$phase_status" >>"$rollback_log"
    return "$status"
  }

  if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
    rollback_ok=false
    phase_status='failed:backup-missing'
  elif ! restore_backups_if_unchanged; then
    rollback_ok=false
    phase_status='failed:source-files-changed-or-backup-mismatch'
    [[ -z "$rollback_log" ]] || printf 'phase=restore-source-files result=%s\n' "$phase_status" >>"$rollback_log"
  else
    [[ -z "$rollback_log" ]] || printf 'phase=restore-source-files result=ok\n' >>"$rollback_log"
  fi

  # Before compensating, ensure the service is still the one this invocation
  # observed. If recreation was attempted, a changed ID is accepted only when
  # it is the ID captured immediately after that attempt; any other ID is an
  # unclassifiable concurrent mutation and must stop with rollback UNKNOWN.
  if [[ "$rollback_ok" == true ]]; then
    if current_id="$(bounded_capture 'rollback container identity inspect' "$inspect_timeout_seconds" \
      "${engine[@]}" inspect --format '{{.Id}}' "$container_name")"; then
      if [[ "$runtime_mutation_attempted" == true ]]; then
        if [[ -n "$runtime_container_id" ]]; then
          if [[ "$current_id" == "$runtime_container_id" ]]; then
            [[ "$runtime_mutation_may_have_changed" == true ]] && should_recreate=true
          elif [[ "$current_id" != "$active_container_id" ]]; then
            rollback_ok=false
            [[ -z "$rollback_log" ]] || printf 'phase=guard-current-container result=failed:unknown-id\n' >>"$rollback_log"
          fi
        elif [[ "$current_id" != "$active_container_id" ]]; then
          rollback_ok=false
          [[ -z "$rollback_log" ]] || printf 'phase=guard-current-container result=failed:unknown-id\n' >>"$rollback_log"
        fi
      elif [[ "$current_id" != "$active_container_id" ]]; then
        rollback_ok=false
        [[ -z "$rollback_log" ]] || printf 'phase=guard-current-container result=failed:unexpected-id\n' >>"$rollback_log"
      fi
    else
      rollback_ok=false
      [[ -z "$rollback_log" ]] || printf 'phase=guard-current-container result=failed:inspect\n' >>"$rollback_log"
    fi
  fi

  if [[ "$rollback_ok" == true && "$image_tag_mutated" == true ]]; then
    if ! rollback_phase 'retag-previous-image' "$recreate_timeout_seconds" \
        "${engine[@]}" image tag "$active_image_id" "$image_ref"; then
      rollback_ok=false
    fi
    if [[ "$rollback_ok" == true ]]; then
      if restored_inspect_seconds="$(rollback_remaining_timeout "$inspect_timeout_seconds")" && \
         restored_image_id="$(timeout --kill-after=5s "${restored_inspect_seconds}s" \
           "${engine[@]}" image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null)" && \
         [[ "$restored_image_id" == "$active_image_id" ]]; then
        [[ -z "$rollback_log" ]] || printf 'phase=verify-retag result=ok\n' >>"$rollback_log"
      else
        [[ -z "$rollback_log" ]] || printf 'phase=verify-retag result=failed:image-id-mismatch\n' >>"$rollback_log"
        rollback_ok=false
      fi
    fi
  fi
  if [[ "$rollback_ok" == true && "$should_recreate" == true ]] && ! rollback_phase 'recreate-previous-service' "$recreate_timeout_seconds" \
        "${compose[@]}" -p "$project_name" -f "$compose_file" up -d --no-build --no-deps --force-recreate otel-collector; then
    rollback_ok=false
  fi
  if [[ "$rollback_ok" == true && "$should_recreate" == true ]]; then
    rollback_health_verified=false
    if [[ "$rollback_ok" == true ]]; then
      rollback_elapsed=0
      rollback_last_health=missing
      # The previous image has a 30s health start period. Wait through that
      # bounded grace before deciding that compensation failed.
      while :; do
        if rollback_health_seconds="$(rollback_remaining_timeout "$inspect_timeout_seconds")" && \
           rollback_last_health="$(timeout --kill-after=5s "${rollback_health_seconds}s" \
            "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
            "$container_name" 2>/dev/null)"; then
          if [[ "$rollback_last_health" == healthy ]]; then
            rollback_container_id=""
            if rollback_container_id="$(bounded_capture 'rollback container identity recheck' "$inspect_timeout_seconds" \
                "${engine[@]}" inspect --format '{{.Id}}' "$container_name")"; then
              if [[ -n "$rollback_container_id" ]] && verify_runtime_state "$active_image_id" \
                  "$expected_config_sha256" "$active_env_sha256" "$active_full_env_sha256" \
                  healthy "$active_runtime_sha256" "$rollback_container_id"; then
                rollback_health_verified=true
                break
              fi
            fi
            break
          fi
          [[ "$rollback_last_health" == unhealthy ]] && break
        else
          break
        fi
        if ! rollback_sleep_seconds="$(rollback_remaining_timeout 5)" || \
           ! timeout --kill-after=5s "${rollback_sleep_seconds}s" sleep "$rollback_sleep_seconds" >/dev/null 2>&1; then
          break
        fi
        (( rollback_elapsed += rollback_sleep_seconds ))
      done
    fi
    if [[ "$rollback_health_verified" != true ]]; then
      [[ -z "$rollback_log" ]] || printf 'phase=verify-previous-runtime result=failed:health=%s\n' "$rollback_last_health" >>"$rollback_log"
      rollback_ok=false
    elif [[ -n "$rollback_log" ]]; then
      printf 'phase=verify-previous-runtime result=ok\n' >>"$rollback_log"
    fi
  fi
  if [[ "$rollback_ok" == true ]]; then
    if [[ -n "$rollback_log" ]]; then
      sha256sum "$rollback_log" >"$backup_dir/rollback.log.sha256"
      chmod 600 "$backup_dir/rollback.log.sha256"
    fi
    printf 'otel installer: failed; rollback verified from %s\n' "$backup_dir" >&2
    exit "$original_status"
  fi
  if [[ -n "$rollback_log" ]]; then
    sha256sum "$rollback_log" >"$backup_dir/rollback.log.sha256"
    chmod 600 "$backup_dir/rollback.log.sha256"
  fi
  printf 'otel installer: rollback UNKNOWN; manual reconciliation required; backup=%s\n' "$backup_dir" >&2
  exit 70
}
trap 'status=$?; if [[ $status -ne 0 ]]; then rollback "$status"; fi' EXIT

# Building can replace the Compose image tag, so image compensation starts
# before the build. Runtime compensation starts only immediately before the
# one-service recreation; a build failure therefore does not disrupt the live
# Collector container.
image_tag_mutated=true
bounded_run 'Collector image build' "$build_timeout_seconds" \
  "${compose[@]}" -p "$project_name" -f "$compose_file" build otel-collector
built_image_id="$(bounded_capture 'built Collector image inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" image inspect --format '{{.Id}}' "$image_ref")"
[[ "$built_image_id" == "$OTEL_EXPECTED_BUILT_IMAGE_ID" ]] || \
  fail 'built image identity does not match OTEL_EXPECTED_BUILT_IMAGE_ID'
assert_active_container_unchanged || fail 'active Collector identity changed during image build'
verify_quiescence_approval "$OTEL_QUIESCE_PROOF" "$active_container_id"
post_build_live_quiescence="$(observe_live_quiescence 'pre-recreate live Collector quiescence' \
  "$quiesce_observation_seconds")" || fail 'live Collector metrics did not prove pre-recreate quiescence'
printf '%s\n' "$post_build_live_quiescence" >"$backup_dir/pre-recreate-live-quiescence.json"
chmod 600 "$backup_dir/pre-recreate-live-quiescence.json"

# Recreate exactly one service after the owner has recorded quiescence. No
# project-wide down, volume deletion, or dependency recreation is allowed.
runtime_mutation_attempted=true
bounded_run 'Collector service recreation' "$recreate_timeout_seconds" \
  "${compose[@]}" -p "$project_name" -f "$compose_file" up -d --no-build --no-deps --force-recreate otel-collector
runtime_container_id="$(bounded_capture 'recreated Collector identity inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{.Id}}' "$container_name")"
[[ -n "$runtime_container_id" && "$runtime_container_id" != "$active_container_id" ]] || \
  fail 'Collector recreation did not produce a new container identity'
runtime_mutation_may_have_changed=true
last_health='missing'
elapsed=0
while (( elapsed <= ready_timeout_seconds )); do
  health_inspect_timeout="$(remaining_timeout "$inspect_timeout_seconds")"
  if health="$(timeout --kill-after=5s "${health_inspect_timeout}s" \
      "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name" 2>/dev/null)"; then
    last_health="$health"
  else
    status=$?
    if [[ "$status" == 124 || "$status" == 137 ]]; then
      fail "Collector health inspect timed out after ${health_inspect_timeout}s"
    fi
    fail "Collector health inspect failed (exit $status)"
  fi
  if [[ "$last_health" == healthy ]]; then
    if verify_runtime_state "$built_image_id" "$expected_config_sha256" "$expected_env_sha256" \
        "$active_full_env_sha256" healthy "$active_runtime_sha256" "$runtime_container_id"; then
      trap - EXIT
      printf 'OTel Collector installed and identity-verified healthy; backup=%s image=%s\n' "$backup_dir" "$built_image_id"
      exit 0
    fi
    fail 'post-install identity verification failed'
  fi
  sleep_seconds=5
  (( ready_timeout_seconds - elapsed < sleep_seconds )) && sleep_seconds=$((ready_timeout_seconds - elapsed))
  (( sleep_seconds > 0 )) || break
  sleep_seconds="$(remaining_timeout "$sleep_seconds")"
  timeout --kill-after=5s "${sleep_seconds}s" sleep "$sleep_seconds" >/dev/null 2>&1 || \
    fail 'Collector readiness wait failed'
  (( elapsed += sleep_seconds ))
done
fail "Collector remained $last_health for ${ready_timeout_seconds}s"
