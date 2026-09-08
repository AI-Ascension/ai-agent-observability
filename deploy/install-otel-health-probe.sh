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
install_mutated=false
backup_dir=""
previous_image_id=""
previous_config_sha256=""
previous_env_sha256=""
previous_full_env_sha256=""
previous_health=""
image_ref=""
install_deadline=0

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

# Keep engine operations bounded and distinguish timeout from a normal command
# failure. Captured output is stdout only so diagnostics cannot echo secrets.
bounded_capture() {
  local label="$1"
  local seconds="$2"
  shift 2
  local output
  local status

  if output="$(timeout --foreground --kill-after=5s "${seconds}s" "$@" 2>/dev/null)"; then
    printf '%s' "$output"
    return 0
  else
    status=$?
  fi
  if [[ "$status" == 124 || "$status" == 137 ]]; then
    fail "$label timed out after ${seconds}s"
  fi
  fail "$label failed (exit $status)"
}

bounded_run() {
  local label="$1"
  local seconds="$2"
  shift 2
  local status

  if timeout --foreground --kill-after=5s "${seconds}s" "$@"; then
    return 0
  else
    status=$?
  fi
  if [[ "$status" == 124 || "$status" == 137 ]]; then
    fail "$label timed out after ${seconds}s"
  fi
  fail "$label failed (exit $status)"
}

case "${OTEL_ENGINE:-podman}" in
  podman)
    command -v podman >/dev/null 2>&1 || fail 'podman is required'
    engine=(podman)
    compose=(podman compose)
    ;;
  docker)
    command -v docker >/dev/null 2>&1 || fail 'docker is required'
    engine=(docker)
    compose=(docker compose)
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
[[ -f "$compose_file" && -f "$collector_config" && -f "$probe_source" && -f "$dockerfile" ]] || \
  fail 'deployment files are incomplete'
[[ -f "$env_file" ]] || fail "missing environment file: $env_file"
require_positive_integer OTEL_BUILD_TIMEOUT_SECONDS "$build_timeout_seconds"
require_positive_integer OTEL_RECREATE_TIMEOUT_SECONDS "$recreate_timeout_seconds"
require_positive_integer OTEL_INSPECT_TIMEOUT_SECONDS "$inspect_timeout_seconds"
require_positive_integer OTEL_READY_TIMEOUT_SECONDS "$ready_timeout_seconds"
require_positive_integer OTEL_INSTALL_TIMEOUT_SECONDS "$install_timeout_seconds"

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

active_image_id="$(bounded_capture 'active Collector image inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{.Image}}' "$container_name")"
need_value OTEL_EXPECTED_ACTIVE_IMAGE_ID
[[ "$active_image_id" == "$OTEL_EXPECTED_ACTIVE_IMAGE_ID" ]] || \
  fail 'active Collector image identity does not match OTEL_EXPECTED_ACTIVE_IMAGE_ID'
active_labels="$(bounded_capture 'active Collector label inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{printf "%s\t%s" (index .Config.Labels "com.docker.compose.project") (index .Config.Labels "com.docker.compose.service")}}' "$container_name")"
[[ "$active_labels" == "$project_name"$'\t'otel-collector ]] || \
  fail 'active Collector Compose project or service identity does not match the reviewed target'
container_inspect="$(bounded_capture 'active Collector container inspect' "$inspect_timeout_seconds" \
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
sys.stdout.write("\\n")
' <<<"$container_inspect")" || fail 'active Collector inspect could not be sanitized'
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
need_value OTEL_EXPECTED_BUILT_IMAGE_ID

command -v flock >/dev/null 2>&1 || fail 'flock is required'
mkdir -p -m 700 "$backup_root"
exec 9>"$backup_root/install.lock"
flock -n 9 || fail 'another OTel installation is already running'

backup_dir="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 700 "$backup_dir"
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
printf '%s\n' "$active_health" >"$backup_dir/previous-health"
printf '%s\n' "$image_ref" >"$backup_dir/previous-image-ref"
sha256sum "$backup_dir"/* >"$backup_dir/SHA256SUMS"
chmod 600 "$backup_dir"/container-inspect.json "$backup_dir"/previous-* "$backup_dir"/SHA256SUMS

verify_runtime_state() {
  local expected_image="$1"
  local expected_config="$2"
  local expected_env_digest="$3"
  local expected_full_env_digest="$4"
  local expected_health="$5"
  local image_id mounts env_text health labels
  local mount_count=0
  local temp

  image_id="$(timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
    "${engine[@]}" inspect --format '{{.Image}}' "$container_name" 2>/dev/null)" || return 1
  [[ "$image_id" == "$expected_image" ]] || return 1
  labels="$(timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
    "${engine[@]}" inspect --format '{{printf "%s\t%s" (index .Config.Labels "com.docker.compose.project") (index .Config.Labels "com.docker.compose.service")}}' "$container_name" 2>/dev/null)" || return 1
  [[ "$labels" == "$project_name"$'\t'otel-collector ]] || return 1
  mounts="$(timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
    "${engine[@]}" inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%t\t%s\n" .Type .Source .Destination .RW .Mode}}{{end}}' "$container_name" 2>/dev/null)" || return 1
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
  if ! timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
      "${engine[@]}" cp "$container_name:$mount_destination" "$temp/config.yaml" >/dev/null 2>&1; then
    rm -rf -- "$temp"
    return 1
  fi
  if [[ "$(sha256_file "$temp/config.yaml")" != "$expected_config" ]]; then
    rm -rf -- "$temp"
    return 1
  fi
  rm -rf -- "$temp"
  env_text="$(timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
    "${engine[@]}" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null)" || return 1
  verify_env_text "$env_text" || return 1
  [[ "$(env_identity "$env_text")" == "$expected_env_digest" ]] || return 1
  [[ "$(env_identity_all "$env_text")" == "$expected_full_env_digest" ]] || return 1
  health="$(timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
    "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name" 2>/dev/null)" || return 1
  [[ "$health" == "$expected_health" ]] || return 1
  return 0
}

rollback() {
  local original_status="$1"
  local rollback_ok=true
  local restored_image_id phase_status
  local rollback_log=""

  trap - EXIT RETURN
  set +e
  if [[ -n "$backup_dir" ]]; then
    rollback_log="$backup_dir/rollback.log"
    : >"$rollback_log"
    chmod 600 "$rollback_log"
  fi
  rollback_phase() {
    local label="$1"
    local seconds="$2"
    shift 2
    local status

    if timeout --foreground --kill-after=5s "${seconds}s" "$@" >/dev/null 2>&1; then
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
  if [[ "$install_mutated" == true ]]; then
    if ! rollback_phase 'retag-previous-image' "$recreate_timeout_seconds" \
        "${engine[@]}" image tag "$active_image_id" "$image_ref"; then
      rollback_ok=false
    fi
    if [[ "$rollback_ok" == true ]]; then
      restored_image_id="$(timeout --foreground --kill-after=5s "${inspect_timeout_seconds}s" \
        "${engine[@]}" image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null)"
      if [[ "$restored_image_id" == "$active_image_id" ]]; then
        [[ -z "$rollback_log" ]] || printf 'phase=verify-retag result=ok\n' >>"$rollback_log"
      else
        [[ -z "$rollback_log" ]] || printf 'phase=verify-retag result=failed:image-id-mismatch\n' >>"$rollback_log"
        rollback_ok=false
      fi
    fi
    if [[ "$rollback_ok" == true ]] && ! rollback_phase 'recreate-previous-service' "$recreate_timeout_seconds" \
        "${compose[@]}" -p "$project_name" -f "$compose_file" up -d --no-build --no-deps --force-recreate otel-collector; then
      rollback_ok=false
    fi
    if [[ "$rollback_ok" == true ]] && ! verify_runtime_state "$active_image_id" "$expected_config_sha256" \
        "$active_env_sha256" "$active_full_env_sha256" "$active_health"; then
      [[ -z "$rollback_log" ]] || printf 'phase=verify-previous-runtime result=failed\n' >>"$rollback_log"
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

install_deadline=$((SECONDS + install_timeout_seconds))
remaining_timeout() {
  local requested="$1"
  local remaining=$((install_deadline - SECONDS))
  (( remaining > 0 )) || fail "overall installation timeout of ${install_timeout_seconds}s exceeded"
  (( requested < remaining )) && printf '%s\n' "$requested" || printf '%s\n' "$remaining"
}

install_mutated=true
bounded_run 'Collector image build' "$(remaining_timeout "$build_timeout_seconds")" \
  "${compose[@]}" -p "$project_name" -f "$compose_file" build otel-collector
built_image_id="$(bounded_capture 'built Collector image inspect' "$(remaining_timeout "$inspect_timeout_seconds")" \
  "${engine[@]}" image inspect --format '{{.Id}}' "$image_ref")"
[[ "$built_image_id" == "$OTEL_EXPECTED_BUILT_IMAGE_ID" ]] || \
  fail 'built image identity does not match OTEL_EXPECTED_BUILT_IMAGE_ID'

# Recreate exactly one service after the owner has recorded quiescence. No
# project-wide down, volume deletion, or dependency recreation is allowed.
bounded_run 'Collector service recreation' "$(remaining_timeout "$recreate_timeout_seconds")" \
  "${compose[@]}" -p "$project_name" -f "$compose_file" up -d --no-build --no-deps --force-recreate otel-collector
last_health='missing'
elapsed=0
while (( elapsed <= ready_timeout_seconds )); do
  health_inspect_timeout="$(remaining_timeout "$inspect_timeout_seconds")"
  if health="$(timeout --foreground --kill-after=5s "${health_inspect_timeout}s" \
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
    if verify_runtime_state "$built_image_id" "$expected_config_sha256" "$expected_env_sha256" "$active_full_env_sha256" healthy; then
      trap - EXIT
      printf 'OTel Collector installed and identity-verified healthy; backup=%s image=%s\n' "$backup_dir" "$built_image_id"
      exit 0
    fi
    fail 'post-install identity verification failed'
  fi
  (( elapsed += 5 ))
  (( elapsed <= ready_timeout_seconds )) && sleep 5
done
fail "Collector remained $last_health for ${ready_timeout_seconds}s"
