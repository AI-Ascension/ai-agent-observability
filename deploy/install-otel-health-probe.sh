#!/usr/bin/env bash
#
# The module split below hoists helpers and shared globals into sourced files,
# so ShellCheck cannot see every cross-file use. The two sourced-module
# diagnostics are disabled file-wide; SC2155/SC2174 remain enabled.
# shellcheck disable=SC2034,SC2154
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

# ---------------------------------------------------------------------------
# Module layout (issue #45 behavior-preserving split)
#
#   otel-installer/lib-common.sh      shared guards, bounds, hashing, timeouts
#   otel-installer/lib-config.sh      dotenv/collector-config parsing + env identity
#   otel-installer/lib-runtime.sh     container runtime identity + contract checks
#   otel-installer/lib-quiescence.sh  approval validation + live metrics observer
#   otel-installer/lib-rollback.sh    backup capture, guarded restore, rollback
#   otel-installer/preflight.sh       read-only preflight (runs on source)
#   otel-installer/install.sh         approved mutation phase (runs on source)
#
# The libraries only define functions. The preflight and install modules contain
# top-level statements and therefore execute in order when sourced; the entry
# point below stays a thin coordinator with no behaviour of its own.
# ---------------------------------------------------------------------------
otel_installer_dir="$script_dir/otel-installer"
for otel_installer_module in \
  lib-common.sh lib-config.sh lib-runtime.sh lib-quiescence.sh lib-rollback.sh \
  preflight.sh install.sh; do
  # shellcheck source=/dev/null
  source "$otel_installer_dir/$otel_installer_module"
done
