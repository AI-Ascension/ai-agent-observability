#!/usr/bin/env bash
set -Eeuo pipefail

# Guarded owner-side installer for the Collector wrapper image. It is a
# deployment handoff, not part of the runtime image and never runs implicitly.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
compose_file="$script_dir/compose.yaml"
collector_config="$script_dir/otel-collector.yaml"
probe_source="$script_dir/otel-health-probe.c"
project_name="${OTEL_COMPOSE_PROJECT:-ai-agent-observability}"
container_name="${OTEL_CONTAINER_NAME:-ai-agent-observability-otel-collector}"
image_ref="${OTEL_IMAGE_REF:-localhost/ai-ascension/ai-agent-observability/otel-collector:0.160.0}"
backup_root="${OTEL_BACKUP_ROOT:-$repo_dir/.otel-health-probe-backups}"
mode="${1:---install}"

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
[[ -f "$compose_file" && -f "$collector_config" && -f "$probe_source" ]] || fail 'deployment files are incomplete'

need_value OTEL_EXPECTED_GIT_HEAD
actual_head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual_head" == "$OTEL_EXPECTED_GIT_HEAD" ]] || fail 'source HEAD does not match OTEL_EXPECTED_GIT_HEAD'
require_hash OTEL_EXPECTED_PROBE_SHA256 "$probe_source"
require_hash OTEL_EXPECTED_CONFIG_SHA256 "$collector_config"
require_hash OTEL_EXPECTED_COMPOSE_SHA256 "$compose_file"

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

# The expected exporter set is an explicit owner input. This prevents a stale
# config or a deliberately disabled backend from being silently accepted.
need_value OTEL_EXPECTED_TRACE_EXPORTERS
IFS=',' read -r -a expected_exporters <<<"$OTEL_EXPECTED_TRACE_EXPORTERS"
for exporter in "${expected_exporters[@]}"; do
  exporter="${exporter#"${exporter%%[![:space:]]*}"}"
  exporter="${exporter%"${exporter##*[![:space:]]}"}"
  [[ -n "$exporter" ]] || fail 'OTEL_EXPECTED_TRACE_EXPORTERS contains an empty entry'
  grep -Fq "$exporter" "$collector_config" || fail "expected exporter is absent: $exporter"
done

"${compose[@]}" -p "$project_name" -f "$compose_file" config --quiet || fail 'Compose model validation failed'

inspect_container() {
  "${engine[@]}" inspect "$container_name" 2>/dev/null
}

active_image_id="$("${engine[@]}" inspect --format '{{.Image}}' "$container_name" 2>/dev/null || true)"
need_value OTEL_EXPECTED_ACTIVE_IMAGE_ID
[[ -n "$active_image_id" && "$active_image_id" == "$OTEL_EXPECTED_ACTIVE_IMAGE_ID" ]] || \
  fail 'active Collector image identity does not match OTEL_EXPECTED_ACTIVE_IMAGE_ID'
container_inspect="$(inspect_container || true)"
[[ -n "$container_inspect" ]] || fail 'active Collector container is unavailable'
grep -Fq '/etc/otelcol-contrib/config.yaml' <<<"$container_inspect" || fail 'active config mount is unavailable'
grep -Fq 'otel-health-probe' <<<"$container_inspect" || fail 'active native probe is unavailable'

if [[ "$mode" == --check ]]; then
  printf '%s\n' 'OTel source, config, Compose, exporter, mount, and active-image guards passed; no mutation performed.'
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
if [[ -f "$script_dir/.env" ]]; then
  backup_file "$script_dir/.env"
  chmod 600 "$backup_dir/.env"
fi
"${engine[@]}" inspect "$container_name" >"$backup_dir/container-inspect.json"
printf '%s\n' "$active_image_id" >"$backup_dir/previous-image-id"
sha256sum "$backup_dir"/* >"$backup_dir/SHA256SUMS"
chmod 600 "$backup_dir"/container-inspect.json "$backup_dir"/previous-image-id "$backup_dir"/SHA256SUMS

rollback() {
  local status="$1"

  set +e
  if [[ "${OTEL_INSTALL_MUTATED:-false}" == true ]]; then
    "${engine[@]}" image tag "$active_image_id" "$image_ref" >/dev/null 2>&1 || true
    "${compose[@]}" -p "$project_name" -f "$compose_file" up -d --no-build --no-deps --force-recreate otel-collector >/dev/null 2>&1 || true
  fi
  printf 'otel installer: failed; rollback attempted from %s\n' "$backup_dir" >&2
  exit "$status"
}
trap 'status=$?; if [[ $status -ne 0 ]]; then rollback "$status"; fi' EXIT

"${compose[@]}" -p "$project_name" -f "$compose_file" build otel-collector
OTEL_INSTALL_MUTATED=true
built_image_id="$("${engine[@]}" image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)"
[[ "$built_image_id" == "$OTEL_EXPECTED_BUILT_IMAGE_ID" ]] || \
  fail 'built image identity does not match OTEL_EXPECTED_BUILT_IMAGE_ID'

# Recreate exactly one service after the owner has recorded quiescence. No
# project-wide down, volume deletion, or dependency recreation is allowed.
"${compose[@]}" -p "$project_name" -f "$compose_file" up -d --no-build --no-deps --force-recreate otel-collector
for _ in $(seq 1 48); do
  health="$("${engine[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name" 2>/dev/null || true)"
  [[ "$health" == healthy ]] && {
    trap - EXIT
    printf 'OTel Collector installed and healthy; backup=%s image=%s\n' "$backup_dir" "$built_image_id"
    exit 0
  }
  sleep 5
done
fail 'Collector did not become healthy within 240 seconds'
