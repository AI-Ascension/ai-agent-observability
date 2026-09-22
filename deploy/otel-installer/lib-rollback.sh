#!/usr/bin/env bash
# OTel installer rollback helpers — preflight backup capture, guarded restore and rollback compensation
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
