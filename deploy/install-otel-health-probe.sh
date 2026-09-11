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
source_manifest="${OTEL_SOURCE_MANIFEST:-$script_dir/.otel-source-manifest.json}"
materialization_backup_dir="${OTEL_MATERIALIZATION_BACKUP_DIR:-}"
expected_candidate_config_user="${OTEL_EXPECTED_CANDIDATE_CONFIG_USER:-10001:10001}"
mount_destination="/etc/otelcol-contrib/config.yaml"
queue_mount_destination="/var/lib/otelcol/file_storage"
queue_volume_name="ai-agent-observability-otel-collector-queue-data"
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
operation_deadline=0
timeout_kill_after_seconds=1
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

canonical_health_status() {
  local value="${1:-}"
  case "$value" in
    ''|missing|null) printf '%s\n' missing ;;
    healthy|unhealthy|starting) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

validate_candidate_config_user() {
  [[ "$expected_candidate_config_user" == 10001:10001 ]] || \
    fail 'OTEL_EXPECTED_CANDIDATE_CONFIG_USER must remain 10001:10001'
  [[ "$1" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || \
    fail 'candidate Config.User must be an explicit UID:GID pair'
  [[ "$1" == "$expected_candidate_config_user" ]] || \
    fail "candidate Config.User must be $expected_candidate_config_user"
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
  local remaining available
  remaining=$((operation_deadline - SECONDS))
  (( remaining > timeout_kill_after_seconds )) || fail "aggregate operation timeout exceeded"
  available=$((remaining - timeout_kill_after_seconds))
  (( requested < available )) && printf '%s\n' "$requested" || printf '%s\n' "$available"
}

rollback_remaining_timeout() {
  local requested="$1"
  local remaining available
  remaining=$((rollback_deadline - SECONDS))
  (( remaining > timeout_kill_after_seconds )) || return 1
  available=$((remaining - timeout_kill_after_seconds))
  (( requested < available )) && printf '%s\n' "$requested" || printf '%s\n' "$available"
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
  if timeout --kill-after="${timeout_kill_after_seconds}s" "${seconds}s" \
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
command -v tar >/dev/null 2>&1 || fail 'tar is required'
command -v cmp >/dev/null 2>&1 || fail 'cmp is required'
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
# Every later bounded operation receives the remaining budget minus the kill
# grace, so a stubborn child cannot make the transaction exceed its deadline.
install_deadline=$((SECONDS + install_timeout_seconds))
operation_deadline=$install_deadline

need_value OTEL_EXPECTED_GIT_HEAD
source_is_git=false
materialized_config_user=""
if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  source_is_git=true
  actual_head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
  [[ "$actual_head" == "$OTEL_EXPECTED_GIT_HEAD" ]] || fail 'source HEAD does not match OTEL_EXPECTED_GIT_HEAD'
  build_input_status="$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all -- \
    deploy/Dockerfile.otel deploy/otel-health-probe.c 2>/dev/null || true)"
  [[ -z "$build_input_status" ]] || fail 'Collector build inputs are dirty'
else
  [[ -f "$source_manifest" ]] || fail 'non-Git source requires OTEL_SOURCE_MANIFEST'
  materialized_config_user="$(python3 - "$source_manifest" "$repo_dir" "$OTEL_EXPECTED_GIT_HEAD" \
    "$expected_candidate_config_user" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

manifest_path, target_text, expected_head, expected_user = sys.argv[1:]
target = Path(os.path.realpath(target_text))
try:
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"source materialization manifest is not valid JSON: {exc}")
if manifest.get("schema") != "otel-source-materialization-v1":
    raise SystemExit("source materialization manifest schema is invalid")
if manifest.get("source_head") != expected_head:
    raise SystemExit("source materialization manifest head does not match OTEL_EXPECTED_GIT_HEAD")
if os.path.realpath(str(manifest.get("target_path", ""))) != str(target):
    raise SystemExit("source materialization manifest target does not match the installer path")
files = manifest.get("files")
if not isinstance(files, list) or not files:
    raise SystemExit("source materialization manifest has no files")
seen = set()
required = {
    "deploy/Dockerfile.otel",
    "deploy/otel-health-probe.c",
    "deploy/otel-collector.yaml",
    "deploy/compose.yaml",
}
for entry in files:
    if not isinstance(entry, dict):
        raise SystemExit("source materialization manifest contains a malformed file entry")
    rel = entry.get("path")
    digest = entry.get("sha256")
    mode = entry.get("mode")
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in Path(rel).parts:
        raise SystemExit("source materialization manifest contains an unsafe path")
    if rel in seen:
        raise SystemExit("source materialization manifest contains a duplicate path")
    seen.add(rel)
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise SystemExit(f"source materialization manifest has an invalid hash for {rel}")
    if not isinstance(mode, int) or mode < 0 or mode > 0o7777:
        raise SystemExit(f"source materialization manifest has an invalid mode for {rel}")
    path = target / rel
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"materialized source file is missing or is a symlink: {rel}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"materialized source hash does not match the reviewed manifest: {rel}")
    if stat.S_IMODE(path.stat().st_mode) != mode:
        raise SystemExit(f"materialized source mode does not match the reviewed manifest: {rel}")
if not required.issubset(seen):
    raise SystemExit("source materialization manifest omits a required deployment input")
source = manifest.get("config_source")
bind = manifest.get("config_bind")
config_user = manifest.get("config_user")
if not isinstance(source, dict) or not isinstance(bind, dict) or source != bind:
    raise SystemExit("source materialization manifest has no matching config source/bind metadata")
if config_user != expected_user or config_user != "10001:10001":
    raise SystemExit("source materialization manifest Config.User does not match the reviewed candidate")
if bind.get("path") != "deploy/otel-collector.yaml":
    raise SystemExit("source materialization manifest config path is invalid")
for field in ("sha256", "mode", "uid", "gid"):
    if field not in bind:
        raise SystemExit(f"source materialization manifest config metadata omits {field}")
if not isinstance(bind["sha256"], str) or len(bind["sha256"]) != 64 or \
   any(char not in "0123456789abcdef" for char in bind["sha256"]):
    raise SystemExit("source materialization manifest config hash is invalid")
if not isinstance(bind["mode"], int) or not 0 <= bind["mode"] <= 0o7777:
    raise SystemExit("source materialization manifest config mode is invalid")
if not isinstance(bind["uid"], int) or bind["uid"] < 0 or \
   not isinstance(bind["gid"], int) or bind["gid"] < 0:
    raise SystemExit("source materialization manifest config uid/gid is invalid")
config_path = target / bind["path"]
config_stat = config_path.lstat()
if config_path.is_symlink() or not config_path.is_file():
    raise SystemExit("materialized Collector config is missing or is a symlink")
actual = {
    "path": bind["path"],
    "sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(),
    "mode": stat.S_IMODE(config_stat.st_mode),
    "uid": config_stat.st_uid,
    "gid": config_stat.st_gid,
}
if actual != bind:
    raise SystemExit("materialized Collector config source/bind metadata changed")
print(config_user)
PY
)" || fail 'source materialization manifest config contract is invalid'
  validate_candidate_config_user "$materialized_config_user"
  [[ -f "$materialization_backup_dir/original-tree.tar" && \
     -f "$materialization_backup_dir/candidate-bind-state.json" ]] || \
    fail 'non-Git source requires a complete materialization backup'
fi
# A materialized non-Git handoff carries the candidate image's exact user in
# its manifest. A direct Git checkout has no source pin for that image yet;
# its runtime user remains part of the captured identity until the owner
# supplies the image-backed materialization contract.
runtime_expected_config_user="$materialized_config_user"
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
grep -Fq 'file_storage/telemetry:' "$collector_config" || fail 'persistent Collector storage extension is absent'
grep -Fq 'storage: file_storage/telemetry' "$collector_config" || fail 'persistent exporter queue storage is absent'
grep -Fq 'sending_queue:' "$collector_config" || \
  fail 'Collector queue metrics are not configured for the quiescence observer'
grep -Fq 'without_type_suffix: true' "$collector_config" || \
  fail 'Collector Prometheus metrics naming is not pinned for the quiescence observer'
grep -Fq 'OTEL_METRICS_PORT' "$compose_file" || fail 'Collector metrics port is not configured'
grep -Fq 'extension.healthcheck.useComponentStatus' "$compose_file" || fail 'component status feature gate is absent'
grep -Fq '/usr/local/bin/otel-health-probe' "$compose_file" || fail 'native probe healthcheck is absent'
grep -Fq './otel-collector.yaml:/etc/otelcol-contrib/config.yaml:ro' "$compose_file" || \
  fail 'collector config mount is not read-only'
grep -Fq 'otel-collector-queue-data:/var/lib/otelcol/file_storage' "$compose_file" || \
  fail 'Collector persistent queue volume is not mounted'
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

active_receivers_text="$(python3 - "$collector_config" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
state = "root"
service_indent = pipelines_indent = traces_indent = receivers_indent = -1
found = False
values = []

def scalar(value):
    value = value.strip()
    if not value:
        raise ValueError("empty receiver")
    if value[0] in "'\"" and value[-1:] == value[0]:
        value = value[1:-1]
    if not value or any(ch.isspace() for ch in value):
        raise ValueError("invalid receiver")
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
        if text.startswith("receivers:"):
            rhs = text[len("receivers:"):].strip()
            found = True
            receivers_indent = indent
            if rhs:
                if not (rhs.startswith("[") and rhs.endswith("]")):
                    raise ValueError("invalid inline receiver list")
                values = [scalar(part) for part in rhs[1:-1].split(",") if part.strip()]
                if not values or len(values) != len(set(values)):
                    raise ValueError("empty or duplicate receiver")
                break
            state = "list"
        continue
    if state == "list":
        if indent <= receivers_indent:
            break
        if not text.startswith("-"):
            raise ValueError("invalid receiver list item")
        values.append(scalar(text[1:]))

if not found or not values or len(values) != len(set(values)):
    raise ValueError("missing or duplicate active receivers")
sys.stdout.write("\n".join(values) + "\n")
PY
)" || fail 'unable to parse active traces receivers'

canonical_expected_list() {
  local name="$1"
  need_value "$name"
  python3 - "$name" "${!name}" <<'PY'
import sys

name, raw = sys.argv[1:]
values = [part.strip() for part in raw.split(",")]
if not values or any(not value or any(ch.isspace() for ch in value) for value in values):
    raise SystemExit(f"{name} contains an empty or malformed entry")
if len(values) != len(set(values)):
    raise SystemExit(f"{name} contains duplicate entries")
sys.stdout.write("\n".join(sorted(values)) + "\n")
PY
}

expected_exporters_canonical="$(canonical_expected_list OTEL_EXPECTED_TRACE_EXPORTERS)" || \
  fail 'OTEL_EXPECTED_TRACE_EXPORTERS is malformed'
active_exporters_canonical="$(printf '%s' "$active_exporters_text" | LC_ALL=C sort)"
[[ "$expected_exporters_canonical" == "$active_exporters_canonical" ]] || \
  fail 'active traces exporter set does not match OTEL_EXPECTED_TRACE_EXPORTERS'
expected_receivers_canonical="$(canonical_expected_list OTEL_EXPECTED_TRACE_RECEIVERS)" || \
  fail 'OTEL_EXPECTED_TRACE_RECEIVERS is malformed'
active_receivers_canonical="$(printf '%s' "$active_receivers_text" | LC_ALL=C sort)"
[[ "$expected_receivers_canonical" == "$active_receivers_canonical" ]] || \
  fail 'active traces receiver set does not match OTEL_EXPECTED_TRACE_RECEIVERS'
expected_receiver_series_canonical="$(canonical_expected_list OTEL_EXPECTED_TRACE_RECEIVER_SERIES)" || \
  fail 'OTEL_EXPECTED_TRACE_RECEIVER_SERIES is malformed'

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
[[ "$metrics_url" == "http://127.0.0.1:${metrics_port}/metrics" ]] || \
  fail 'OTEL_METRICS_URL must be the configured loopback metrics endpoint'

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
queue_mount_matches() {
  local inspect_json="$1"
  jq -e --arg destination "$queue_mount_destination" --arg volume "$queue_volume_name" '
    [.[0].Mounts[]? | select((.Destination // "") == $destination)] as $mounts |
    ($mounts | length) == 1 and
    ($mounts[0].Type // "") == "volume" and
    ($mounts[0].Name // "") == $volume and
    ($mounts[0].Destination // "") == $destination and
    ($mounts[0].RW // false) == true
  ' <<<"$inspect_json" >/dev/null
}
queue_mount_matches "$container_inspect_raw" || \
  fail 'active Collector persistent queue volume is missing, wrong, or read-only'
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
  "${engine[@]}" inspect "$container_name")"
active_healthcheck_sha256="$(jq -cS '.[0].Config.Healthcheck // null' <<<"$active_healthcheck" | \
  sha256sum | awk '{print $1}')" || fail 'active Collector healthcheck identity is unavailable'
if [[ -n "${OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256:-}" && \
      "$active_healthcheck_sha256" != "$OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256" ]]; then
  fail 'active Collector healthcheck baseline does not match OTEL_EXPECTED_ACTIVE_HEALTHCHECK_SHA256'
fi
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
    ($health.Test == ["CMD", $probe]) and
    ($health.Interval == 30000000000) and
    ($health.Timeout == 5000000000) and
    ($health.StartPeriod == 30000000000) and
    ($health.Retries == 3)
  ' <<<"$inspect_json" >/dev/null
}
healthcheck_identity_matches() {
  local inspect_json="$1"
  local expected_sha256="$2"
  [[ "$(jq -cS '.[0].Config.Healthcheck // null' <<<"$inspect_json" | \
    sha256sum | awk '{print $1}')" == "$expected_sha256" ]]
}
# The pre-install container is a legacy baseline. Its healthcheck may be
# absent or older; the candidate contract is enforced after recreation.
healthcheck_identity_matches "$container_inspect_raw" "$active_healthcheck_sha256" || \
  fail 'active Collector legacy healthcheck baseline changed during preflight'
active_runtime_sha256="$(runtime_identity "$container_inspect_raw" | sha256sum | awk '{print $1}')"
[[ "$active_runtime_sha256" =~ ^[0-9a-f]{64}$ ]] || fail 'active Collector runtime identity is unavailable'

metrics_port_binding_contract_matches() {
  local inspect_json="$1"
  local binding_result
  binding_result="$(jq -r --arg host_port "$metrics_port" '
    .[0].HostConfig.PortBindings as $bindings |
    (($bindings["8888/tcp"] // []) | length) == 1 and
    (($bindings["8888/tcp"][0].HostIp // "") == "127.0.0.1") and
    (($bindings["8888/tcp"][0].HostPort // "") == $host_port)
  ' <<<"$inspect_json")" || return 1
  [[ "$binding_result" == true ]]
}

metrics_port_binding_contract_matches "$container_inspect_raw" || \
  fail 'active Collector does not own the configured loopback metrics port'

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
    raise SystemExit(f"quiescence approval is stale or from the future (age={age:.3f}s max_age={max_age}s)")
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
    "$quiesce_observation_seconds" "$expected_exporters_canonical" \
    "$expected_receiver_series_canonical" <<'PY'
import json
import math
import re
import sys
import time
import urllib.error
import urllib.request

url, duration_text, expected_exporters_text, expected_receiver_series_text = sys.argv[1:]
try:
    duration = int(duration_text)
except ValueError:
    raise SystemExit("OTEL_QUIESCE_OBSERVATION_SECONDS must be an integer")
if duration < 5 or duration > 120:
    raise SystemExit("OTEL_QUIESCE_OBSERVATION_SECONDS is outside 5..120")
expected_exporters = set(expected_exporters_text.splitlines())
expected_receiver_series = set(expected_receiver_series_text.splitlines())
if not expected_exporters or any(not value for value in expected_exporters):
    raise SystemExit("expected exporter set is empty or malformed")
if not expected_receiver_series or any("/" not in value or value.count("/") != 1 for value in expected_receiver_series):
    raise SystemExit("expected receiver series set is empty or malformed")

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
        if match.group(1) in labels:
            raise ValueError("duplicate Prometheus label")
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
        match = sample_re.fullmatch(line)
        if not match:
            raise RuntimeError("malformed Prometheus metric sample")
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
    def exporter_values(series, label):
        values = {}
        for labels, value in series:
            exporter = labels.get("exporter")
            if exporter not in expected_exporters:
                raise RuntimeError(f"unexpected or missing {label} exporter label")
            if exporter in values:
                raise RuntimeError(f"duplicate {label} series for exporter {exporter}")
            values[exporter] = value
        if set(values) != expected_exporters:
            raise RuntimeError(f"{label} series do not exactly match expected exporters")
        return values
    queue_values = exporter_values(queues, "queue")
    in_flight_values = exporter_values(in_flight, "in-flight")
    receiver_values = {}
    for labels, value in accepted:
        receiver = labels.get("receiver")
        transport = labels.get("transport")
        series = f"{receiver}/{transport}"
        if receiver is None or transport is None or series not in expected_receiver_series:
            raise RuntimeError("unexpected or malformed receiver accepted-span series")
        if series in receiver_values:
            raise RuntimeError(f"duplicate accepted-span series for receiver {series}")
        receiver_values[series] = value
    if set(receiver_values) != expected_receiver_series:
        raise RuntimeError("accepted-span series do not exactly match expected receivers")
    if any(value < 0 for value in receiver_values.values()):
        raise RuntimeError("live Collector accepted-span counter is negative")
    if any(value != 0 for value in queue_values.values()):
        raise RuntimeError("live Collector exporter queue is not empty")
    if any(value != 0 for value in in_flight_values.values()):
        raise RuntimeError("live Collector exporter has in-flight requests")
    return {
        "queue_depth": int(sum(queue_values.values())),
        "in_flight_requests": int(sum(in_flight_values.values())),
        "accepted_spans": sum(receiver_values.values()),
        "queue_series": len(queue_values),
        "accepted_series": len(receiver_values),
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

active_health_raw="$(bounded_capture 'active Collector health inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name")"
active_health="$(canonical_health_status "$active_health_raw")" || \
  fail "active Collector legacy baseline has an invalid health status (status=$active_health_raw)"
case "$active_health" in
  healthy|missing) ;;
  *) fail "active Collector legacy baseline is not ready (status=$active_health)" ;;
esac

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

verify_materialized_source_for_rollback() {
  [[ -n "$materialization_backup_dir" ]] || return 0
  [[ -f "$source_manifest" && -f "$materialization_backup_dir/candidate-source-manifest.json" && \
     -f "$materialization_backup_dir/original-tree.tar" && \
     -f "$materialization_backup_dir/original-tree-manifest.json" && \
     -f "$materialization_backup_dir/original-bind-state.json" && \
     -f "$materialization_backup_dir/candidate-bind-state.json" ]] || return 1
  cmp -s -- "$source_manifest" "$materialization_backup_dir/candidate-source-manifest.json" || return 1
  python3 - "$source_manifest" "$repo_dir" "$OTEL_EXPECTED_GIT_HEAD" \
    "$materialization_backup_dir/candidate-bind-state.json" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

source_manifest, target_text, expected_head, bind_state_path = sys.argv[1:]
target = Path(os.path.realpath(target_text))
manifest = json.loads(Path(source_manifest).read_text(encoding="utf-8"))
if manifest.get("schema") != "otel-source-materialization-v1":
    raise SystemExit("source materialization manifest schema is invalid")
if manifest.get("source_head") != expected_head:
    raise SystemExit("source materialization manifest head changed")
if os.path.realpath(str(manifest.get("target_path", ""))) != str(target):
    raise SystemExit("source materialization manifest target changed")
for entry in manifest.get("files", []):
    rel = entry.get("path")
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in Path(rel).parts:
        raise SystemExit("source materialization manifest contains an unsafe path")
    path = target / rel
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"materialized source file changed type: {rel}")
    if stat.S_IMODE(path.stat().st_mode) != entry.get("mode"):
        raise SystemExit(f"materialized source mode changed: {rel}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry.get("sha256"):
        raise SystemExit(f"materialized source content changed: {rel}")
bind_state = json.loads(Path(bind_state_path).read_text(encoding="utf-8"))
if bind_state.get("schema") != "otel-bind-state-v1":
    raise SystemExit("candidate bind state schema is invalid")
for entry in bind_state.get("entries", []):
    path = target / entry["path"]
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_dev != entry["device"] or st.st_ino != entry["inode"]:
        raise SystemExit(f"materialized bind-source inode changed: {entry['path']}")
    if stat.S_IMODE(st.st_mode) != entry["mode"]:
        raise SystemExit(f"materialized bind-source mode changed: {entry['path']}")
    if st.st_uid != entry["uid"] or st.st_gid != entry["gid"]:
        raise SystemExit(f"materialized bind-source uid/gid changed: {entry['path']}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        if entry["path"] == "deploy/.env":
            raise SystemExit("materialized environment source changed")
        raise SystemExit(f"materialized bind-source content changed: {entry['path']}")
PY
}

restore_materialized_source_if_unchanged() {
  [[ -n "$materialization_backup_dir" ]] || return 0
  verify_materialized_source_for_rollback || return 1
  local archive="$materialization_backup_dir/original-tree.tar"
  local original_manifest="$materialization_backup_dir/original-tree-manifest.json"
  local candidate_manifest="$materialization_backup_dir/candidate-source-manifest.json"
  local seconds
  seconds="$(operation_timeout "$recreate_timeout_seconds")" || return 1
  timeout --kill-after="${timeout_kill_after_seconds}s" "${seconds}s" \
    tar --xattrs --acls --no-same-owner --preserve-permissions -C "$repo_dir" -xpf "$archive" || return 1
  seconds="$(operation_timeout "$inspect_timeout_seconds")" || return 1
  timeout --kill-after="${timeout_kill_after_seconds}s" "${seconds}s" \
    python3 - "$repo_dir" "$candidate_manifest" "$original_manifest" <<'PY' || return 1
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
candidate = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
original = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
candidate_paths = {entry["path"] for entry in candidate["files"]}
original_paths = {entry["path"] for entry in original["entries"]}
for rel in sorted(candidate_paths - original_paths, key=lambda value: (value.count("/"), value), reverse=True):
    path = root / rel
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        raise SystemExit(f"candidate-only rollback path is not a file: {rel}")
PY
  rm -f -- "$source_manifest"
  # The old tree was extracted over the same paths, preserving existing bind
  # source inodes. Verify original bytes and modes before declaring source
  # compensation successful.
  python3 - "$repo_dir" "$original_manifest" "$materialization_backup_dir/original-bind-state.json" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
tree = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
for entry in tree.get("entries", []):
    path = root / entry["path"]
    st = path.lstat()
    if stat.S_IMODE(st.st_mode) != entry["mode"]:
        raise SystemExit(f"restored source mode mismatch: {entry['path']}")
    if entry["type"] == "file":
        if not stat.S_ISREG(st.st_mode) or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise SystemExit(f"restored source content mismatch: {entry['path']}")
    elif entry["type"] == "symlink":
        if not stat.S_ISLNK(st.st_mode) or hashlib.sha256(os.readlink(path).encode()).hexdigest() != entry["sha256"]:
            raise SystemExit(f"restored source symlink mismatch: {entry['path']}")
    elif not stat.S_ISDIR(st.st_mode):
        raise SystemExit(f"restored source directory mismatch: {entry['path']}")
bind_state = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
for entry in bind_state.get("entries", []):
    path = root / entry["path"]
    st = path.lstat()
    if st.st_dev != entry["device"] or st.st_ino != entry["inode"]:
        raise SystemExit(f"restored bind-source inode mismatch: {entry['path']}")
    if stat.S_IMODE(st.st_mode) != entry["mode"]:
        raise SystemExit(f"restored bind-source mode mismatch: {entry['path']}")
    if st.st_uid != entry["uid"] or st.st_gid != entry["gid"]:
        raise SystemExit(f"restored bind-source uid/gid mismatch: {entry['path']}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit(f"restored bind-source content mismatch: {entry['path']}")
PY
}

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
  local healthcheck_mode="${8:-candidate}"
  local expected_healthcheck_sha256="${9:-$active_healthcheck_sha256}"
  local expected_user="${10:-$runtime_expected_config_user}"
  local inspect_json image_id mounts env_text health_raw health labels runtime_sha256 cp_seconds state_status config_user
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
  config_user="$(jq -r '.[0].Config.User // ""' <<<"$inspect_json")" || return 1
  if [[ -n "$expected_user" && "$config_user" != "$expected_user" ]]; then
    return 1
  fi
  labels="$(jq -r '.[0].Config.Labels as $l | (($l["com.docker.compose.project"] // "") + "\t" + ($l["com.docker.compose.service"] // ""))' <<<"$inspect_json")" || return 1
  [[ "$labels" == "$project_name"$'\t'otel-collector ]] || return 1
  metrics_port_binding_contract_matches "$inspect_json" || return 1
  queue_mount_matches "$inspect_json" || return 1
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
  if ! timeout --kill-after="${timeout_kill_after_seconds}s" "${cp_seconds}s" \
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
  health_raw="$(jq -r '.[0].State.Health.Status // "missing"' <<<"$inspect_json")" || return 1
  health="$(canonical_health_status "$health_raw")" || return 1
  [[ "$health" == "$expected_health" ]] || return 1
  state_status="$(jq -r '.[0].State.Status // "missing"' <<<"$inspect_json")" || return 1
  [[ "$state_status" == running ]] || return 1
  if [[ "$healthcheck_mode" == candidate ]]; then
    healthcheck_contract_matches "$inspect_json" || return 1
  elif [[ "$healthcheck_mode" == baseline ]]; then
    healthcheck_identity_matches "$inspect_json" "$expected_healthcheck_sha256" || return 1
  else
    return 1
  fi
  return 0
}

verify_source_files_unchanged() {
  require_hash OTEL_EXPECTED_PROBE_SHA256 "$probe_source"
  require_hash OTEL_EXPECTED_CONFIG_SHA256 "$collector_config"
  require_hash OTEL_EXPECTED_COMPOSE_SHA256 "$compose_file"
  require_hash OTEL_EXPECTED_DOCKERFILE_SHA256 "$dockerfile"
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
    if timeout --kill-after="${timeout_kill_after_seconds}s" "${seconds}s" "$@" >/dev/null 2>&1; then
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
  elif ! restore_materialized_source_if_unchanged; then
    rollback_ok=false
    phase_status='failed:materialized-source-changed-or-backup-mismatch'
    [[ -z "$rollback_log" ]] || printf 'phase=restore-materialized-source result=%s\n' "$phase_status" >>"$rollback_log"
  else
    [[ -z "$rollback_log" ]] || printf 'phase=restore-source-files result=ok\n' >>"$rollback_log"
    [[ -z "$rollback_log" ]] || printf 'phase=restore-materialized-source result=ok\n' >>"$rollback_log"
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
         restored_image_id="$(timeout --kill-after="${timeout_kill_after_seconds}s" "${restored_inspect_seconds}s" \
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
           rollback_health_raw="$(timeout --kill-after="${timeout_kill_after_seconds}s" "${rollback_health_seconds}s" \
            "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
            "$container_name" 2>/dev/null)" && \
           rollback_last_health="$(canonical_health_status "$rollback_health_raw")"; then
          if [[ "$rollback_last_health" == "$active_health" ]]; then
            rollback_container_id=""
            if rollback_container_id="$(bounded_capture 'rollback container identity recheck' "$inspect_timeout_seconds" \
                "${engine[@]}" inspect --format '{{.Id}}' "$container_name")"; then
              if [[ -n "$rollback_container_id" ]] && verify_runtime_state "$active_image_id" \
                  "$expected_config_sha256" "$active_env_sha256" "$active_full_env_sha256" \
                  "$active_health" "$active_runtime_sha256" "$rollback_container_id" baseline \
                  "$active_healthcheck_sha256" ""; then
                rollback_health_verified=true
                break
              fi
            fi
            break
          fi
          [[ "$rollback_last_health" == unhealthy || "$rollback_last_health" == starting || \
             "$rollback_last_health" == missing ]] && break
        else
          break
        fi
        if ! rollback_sleep_seconds="$(rollback_remaining_timeout 5)" || \
           ! timeout --kill-after="${timeout_kill_after_seconds}s" "${rollback_sleep_seconds}s" sleep "$rollback_sleep_seconds" >/dev/null 2>&1; then
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
  env BUILDAH_FORMAT=docker "${compose[@]}" -p "$project_name" -f "$compose_file" build otel-collector
built_image_id="$(bounded_capture 'built Collector image inspect' "$inspect_timeout_seconds" \
  "${engine[@]}" image inspect --format '{{.Id}}' "$image_ref")"
[[ "$built_image_id" == "$OTEL_EXPECTED_BUILT_IMAGE_ID" ]] || \
  fail 'built image identity does not match OTEL_EXPECTED_BUILT_IMAGE_ID'
assert_active_container_unchanged || fail 'active Collector identity changed during image build'
verify_source_files_unchanged || fail 'reviewed source inputs changed during image build'
verify_runtime_state "$active_image_id" "$expected_config_sha256" "$active_env_sha256" \
  "$active_full_env_sha256" "$active_health" "$active_runtime_sha256" "$active_container_id" baseline \
  "$active_healthcheck_sha256" "" || \
  fail 'active Collector runtime contract changed during image build'
verify_quiescence_approval "$OTEL_QUIESCE_PROOF" "$active_container_id"
post_build_live_quiescence="$(observe_live_quiescence 'pre-recreate live Collector quiescence' \
  "$quiesce_observation_seconds")" || fail 'live Collector metrics did not prove pre-recreate quiescence'
printf '%s\n' "$post_build_live_quiescence" >"$backup_dir/pre-recreate-live-quiescence.json"
chmod 600 "$backup_dir/pre-recreate-live-quiescence.json"
verify_source_files_unchanged || fail 'reviewed source inputs changed before recreation'
verify_runtime_state "$active_image_id" "$expected_config_sha256" "$active_env_sha256" \
  "$active_full_env_sha256" "$active_health" "$active_runtime_sha256" "$active_container_id" baseline \
  "$active_healthcheck_sha256" "" || \
  fail 'active Collector runtime contract changed immediately before recreation'

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
ready_deadline=$((SECONDS + ready_timeout_seconds))
operation_deadline=$ready_deadline
while (( SECONDS < ready_deadline )); do
  health_inspect_timeout="$(operation_timeout "$inspect_timeout_seconds")"
  if health_raw="$(timeout --kill-after="${timeout_kill_after_seconds}s" "${health_inspect_timeout}s" \
      "${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name" 2>/dev/null)"; then
    if ! health="$(canonical_health_status "$health_raw")"; then
      fail "Collector health inspect returned an invalid status (status=$health_raw)"
    fi
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
  ready_remaining=$((ready_deadline - SECONDS))
  (( ready_remaining < sleep_seconds )) && sleep_seconds=$ready_remaining
  (( sleep_seconds > 0 )) || break
  sleep_seconds="$(operation_timeout "$sleep_seconds")"
  timeout --kill-after="${timeout_kill_after_seconds}s" "${sleep_seconds}s" sleep "$sleep_seconds" >/dev/null 2>&1 || \
    fail 'Collector readiness wait failed'
done
fail "Collector remained $last_health for ${ready_timeout_seconds}s"
