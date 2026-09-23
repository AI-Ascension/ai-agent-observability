#!/usr/bin/env bash
# OTel installer preflight — read-only validation executed when the coordinator sources this file
#
# Extracted verbatim from deploy/install-otel-health-probe.sh by the
# behavior-preserving module split in issue #45. This file is sourced by the
# installer coordinator and defines functions only; it is never executed
# directly.
#
# ShellCheck cannot follow the coordinator's `source` chain, so shared
# globals and helper functions appear "unused" or "unassigned" per file.
# The two diagnostics below are disabled file-wide for that reason.
# shellcheck disable=SC2034,SC2154

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
    deploy/Dockerfile.otel deploy/otel-health-probe.c deploy/otel-probe 2>/dev/null || true)"
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
expected_env_names=(MLFLOW_EXPERIMENT_ID LAMINAR_PROJECT_API_KEY)
declare -A expected_env
for env_name in "${expected_env_names[@]}"; do
  expected_env["$env_name"]="$(dotenv_value "$env_name")"
done
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
active_full_env_sha256="$(env_identity_all "$active_env_text")"
active_container_id="$(jq -r '.[0].Id // ""' <<<"$container_inspect_raw")"
[[ -n "$active_container_id" ]] || fail 'active Collector container identity is unavailable'
active_state_status="$(jq -r '.[0].State.Status // "missing"' <<<"$container_inspect_raw")"
[[ "$active_state_status" == running ]] || \
  fail "active Collector is not running (state=$active_state_status)"
# The pre-install container is a legacy baseline. Its healthcheck may be
# absent or older; the candidate contract is enforced after recreation.
healthcheck_identity_matches "$container_inspect_raw" "$active_healthcheck_sha256" || \
  fail 'active Collector legacy healthcheck baseline changed during preflight'
active_runtime_sha256="$(runtime_identity "$container_inspect_raw" | sha256sum | awk '{print $1}')"
[[ "$active_runtime_sha256" =~ ^[0-9a-f]{64}$ ]] || fail 'active Collector runtime identity is unavailable'

metrics_port_binding_contract_matches "$container_inspect_raw" || \
  fail 'active Collector does not own the configured loopback metrics port'
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
