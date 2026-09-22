#!/usr/bin/env bash
# OTel installer mutation phase — approved backup capture, image build, single-service recreation and readiness verification; executed when sourced
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
