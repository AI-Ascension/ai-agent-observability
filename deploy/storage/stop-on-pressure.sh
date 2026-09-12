#!/usr/bin/env bash
# Root-owned timer entrypoint. It never starts a service or clears a stop latch.
set -euo pipefail
[[ $# == 0 && $EUID == 0 ]] || { echo 'Root, no arguments required.' >&2; exit 77; }
readonly state_dir=/var/lib/ai-agent-observability/storage-isolation
readonly manifest=/etc/ai-agent-observability/storage.tsv
readonly checker=/opt/ai-agent-observability/deploy/storage/check-storage.sh
readonly manifest_checker=/opt/ai-agent-observability/deploy/storage/require-root-manifest.sh
umask 077
install -d -m 0700 "$state_dir"
exec 9>"$state_dir/lock"
flock -n 9 || exit 0
if [[ ! -e "$state_dir/stopped" ]] && bash "$manifest_checker" "$manifest" && bash "$checker" --manifest "$manifest" >/dev/null; then
  exit 0
fi
# Persist the latch BEFORE stopping; failed stop is retried by the timer. Keep a
# single small status file, not one growing incident file per repeated failure.
if [[ ! -e "$state_dir/stopped" ]]; then
  printf '%s\n' 'Storage admission failed; ingestion and ClickHouse stop requested.' >"$state_dir/stopped"
  echo 'Storage admission failed; stopping Collector, Laminar ingest and ClickHouse.' >&2
fi
failed=0
for container in ai-agent-observability-otel-collector ai-agent-observability-laminar-app-server ai-agent-observability-laminar-clickhouse; do
  # Missing containers are an inspection failure rather than proof of safe shutdown.
  running=$(timeout 20s podman inspect --format '{{.State.Running}}' "$container") || { failed=1; continue; }
  case "$running" in
    false) ;;
    true)
      # Podman stop may terminate forcibly at its grace limit. The owner must have
      # a consistent backup; this emergency limit protects the host from exhaustion.
      timeout 75s podman stop --time 60 "$container" >/dev/null || failed=1
      ;;
    *) failed=1 ;;
  esac
done
((failed == 0)) || { echo 'Storage stop incomplete; latch retained and timer will retry.' >&2; exit 1; }
