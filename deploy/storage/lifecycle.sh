#!/usr/bin/env bash
# Sourced by the root-only lifecycle entrypoints. Arguments aid disposable tests;
# production entrypoints always supply fixed, administrator-owned state paths.

storage_take_lock() {
  local runtime_dir=$1 wait_seconds=$2
  [[ ! -L "$runtime_dir" ]] || return 1
  install -d -m 0700 -- "$runtime_dir" || return 1
  [[ $(stat -c %u -- "$runtime_dir") == "$EUID" ]] || return 1
  [[ ! -L "$runtime_dir/lock" ]] || return 1
  exec 9>"$runtime_dir/lock" || return 1
  # Both startup and the pressure monitor hold this descriptor until process exit.
  # 75 distinguishes a busy lifecycle from a lock infrastructure failure.
  flock -E 75 -w "$wait_seconds" 9
}

storage_latch_stop() {
  local state_dir=$1 runtime_dir=$2 failed=0
  # Failure to persist a marker must never prevent the actual emergency stop.
  # The /run marker also blocks starts if the root filesystem cannot allocate.
  if ! touch -- "$runtime_dir/stopped"; then
    echo 'Unable to write runtime stop latch.' >&2
    failed=1
  fi
  if [[ -L "$state_dir" ]] || ! install -d -m 0700 -- "$state_dir" ||
     [[ -L "$state_dir/stopped" ]] || ! touch -- "$state_dir/stopped"; then
    echo 'Unable to persist stop latch; reconcile before reboot or restart.' >&2
    failed=1
  fi
  return "$failed"
}

storage_stop_containers() {
  local container running failed=0
  for container in ai-agent-observability-otel-collector ai-agent-observability-laminar-app-server ai-agent-observability-laminar-clickhouse; do
    running=$(timeout 20s podman inspect --format '{{.State.Running}}' "$container") || { failed=1; continue; }
    case "$running" in
      false) ;;
      true) timeout 75s podman stop --time 60 "$container" >/dev/null || failed=1 ;;
      *) failed=1 ;;
    esac
  done
  return "$failed"
}
