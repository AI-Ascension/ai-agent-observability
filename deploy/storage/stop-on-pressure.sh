#!/usr/bin/env bash
# Root-owned timer entrypoint. It never starts a service or clears a stop latch.
set -euo pipefail
[[ $# == 0 && $EUID == 0 ]] || { echo 'Root, no arguments required.' >&2; exit 77; }
readonly state_dir=/var/lib/ai-agent-observability/storage-isolation
readonly manifest=/etc/ai-agent-observability/storage.tsv
readonly checker=/opt/ai-agent-observability/deploy/storage/check-storage.sh
readonly manifest_checker=/opt/ai-agent-observability/deploy/storage/require-root-manifest.sh
readonly bind_checker=/opt/ai-agent-observability/deploy/storage/check-bind-paths.sh
readonly runtime_dir=/run/ai-agent-observability-storage
# shellcheck source=deploy/storage/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
umask 077
lock_status=0
storage_take_lock "$runtime_dir" 0 || lock_status=$?
[[ $lock_status != 75 ]] || exit 0
if [[ $lock_status == 0 && ! -e "$state_dir/stopped" && ! -e "$runtime_dir/stopped" ]] &&
   bash "$manifest_checker" "$manifest" && bash "$checker" --manifest "$manifest" >/dev/null &&
   bash "$bind_checker" "$manifest"; then
  exit 0
fi
failed=0
storage_latch_stop "$state_dir" "$runtime_dir" || failed=1
echo 'Storage admission failed; stopping Collector, Laminar ingest and ClickHouse.' >&2
# A missing container or failed stop is an error, but does not skip later stops.
# Podman may force termination after 60 seconds; this is emergency containment.
storage_stop_containers || failed=1
((failed == 0)) || { echo 'Storage stop or latch incomplete; timer will retry.' >&2; exit 1; }
