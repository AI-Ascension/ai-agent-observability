#!/usr/bin/env bash
set -Eeuo pipefail

# Source contracts for the privileged wrapper. Runtime fixture coverage must
# exercise the installed root-owned copy; this test never fakes ownership.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$repo_root/deploy/ai-agent-observability-reviewed-upgrade"
materializer="$repo_root/deploy/materialize-otel-source.sh"

bash -n "$wrapper" "$materializer"
[[ -x "$wrapper" && -x "$materializer" ]]
grep -Fqx '#!/bin/bash -p' "$wrapper"
grep -Fq "readonly install_config='/etc/ai-agent-observability-reviewed-upgrade.conf'" "$wrapper"
grep -Fq 'trusted_path "$deployment_root" && trusted_path "$deployment_dir" && trusted_path "$candidate_root" && trusted_path "$backup_root"' "$wrapper"
grep -Fq 'non_overlapping_paths "$candidate_real" "$deployment_real"' "$wrapper"
grep -Fq 'non_overlapping_paths "$backup_real" "$deployment_real"' "$wrapper"
grep -Fq 'non_overlapping_paths "$candidate_real" "$backup_real"' "$wrapper"
grep -Fq 'project-volume inventory failed' "$wrapper"
grep -Fq 'project-network inventory failed' "$wrapper"
grep -Fq 'BASELINE_COMPOSE_SHA256' "$wrapper"
grep -Fq 'BASELINE_COMPOSE_SHA256=6a4f31c411d03e54a6d0d88ef0bc6d65fc18061e1adafc7af94d8f08c6dd7b6f' "$repo_root/deploy/ai-agent-observability-reviewed-upgrade.conf.example"
grep -Fq 'readonly -a baseline_services=' "$wrapper"
grep -Fq 'readonly -a baseline_volumes=' "$wrapper"
grep -Fq "live Compose source is not the reviewed migration baseline" "$wrapper"
grep -Fq 'candidate-only container exists before migration' "$wrapper"
grep -Fq 'candidate-only volume exists before migration' "$wrapper"
grep -Fq 'baseline-objects.json' "$wrapper"
grep -Fq '"preexisting"' "$wrapper"
grep -Fq 'stop_and_verify_baseline()' "$wrapper"
grep -Fq 'record_created_objects()' "$wrapper"
grep -Fq 'remove_recorded_created_containers()' "$wrapper"
grep -Fq 'container rm -f' "$wrapper"
grep -Fq 'for volume in "${baseline_volumes[@]}"; do' "$wrapper"
grep -Fq 'declare -A baseline_container_ids=()' "$wrapper"
grep -Fq '"${baseline_container_ids[$service]}|$project_name|$service"' "$wrapper"
grep -Fq 'while parent != Path("."):' "$wrapper"
if rg -n 'volume rm|compose .* down|down -v' "$wrapper"; then
  printf '%s\n' 'wrapper must not delete volumes or use project-wide down' >&2
  exit 1
fi
grep -Fq "container inspect --format '{{.State.Running}}'" "$wrapper"
grep -Fq 'stop_and_verify_baseline || true' "$wrapper"
grep -Fq 'if ! stop_and_verify_baseline; then' "$wrapper"
grep -Fq 'discover_materialization_backup()' "$wrapper"
grep -Fq 'bounded "$operation_timeout_seconds" env -i' "$wrapper"
if rg -n 'find "\$candidate_root" -xdev' "$wrapper"; then
  printf '%s\n' 'candidate trust must include mounted descendants' >&2
  exit 1
fi
grep -Fq 'untrusted="$(find "$candidate_root"' "$wrapper"
grep -Fq '2>/dev/null)" || return 1' "$wrapper"
if ! awk '/^materialized=true$/{armed=NR} /OTEL_SOURCE_MATERIALIZE_APPROVED=true/{action=NR} END{exit !(armed && action && armed < action)}' "$wrapper"; then
  printf '%s\n' 'reconciliation is not armed before materialization' >&2
  exit 1
fi
if rg -n '(materialize|rollback)\.(stdout|stderr)|--backup-root|--candidate-root|--deployment-root|--engine-bin' "$wrapper"; then
  printf '%s\n' 'wrapper retains unbounded materializer logs or caller path controls' >&2
  exit 1
fi
grep -Fq '    /usr/bin/podman)' "$materializer"
grep -Fq 'OTEL_CANDIDATE_READER_ENGINE must be podman, docker, or /usr/bin/podman' "$materializer"
bash "$repo_root/tests/reviewed-upgrade-wrapper-engine-fixture.sh"
printf '%s\n' 'Reviewed upgrade wrapper source contracts passed (privileged runtime fixture remains separate).'
