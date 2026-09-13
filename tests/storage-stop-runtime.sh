#!/usr/bin/env bash
# Real helper/Podman integration, exclusively on an isolated disposable CI runner.
set -euo pipefail
[[ ${CI:-} == true && $EUID == 0 && $# == 1 ]] || {
  echo 'Requires a disposable CI runner, root and one local immutable image.' >&2
  exit 77
}
image=$1
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ || "$image" =~ @sha256:[0-9a-f]{64}$ ]] || exit 64
command -v podman >/dev/null || exit 77
podman image exists "$image" || exit 77
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=deploy/storage/lifecycle.sh
source "$repo_root/deploy/storage/lifecycle.sh"
names=(ai-agent-observability-otel-collector ai-agent-observability-laminar-app-server ai-agent-observability-laminar-clickhouse)
ids=()
for name in "${names[@]}"; do
  status=0
  podman container exists "$name" || status=$?
  [[ $status == 1 ]] || { echo 'Reserved service name exists or inventory failed; refusing runtime test.' >&2; exit 77; }
done
cleanup() {
  local status=$? id
  # IDs come only from successful creates in this invocation, never name lookup.
  for id in "${ids[@]}"; do
    podman rm -f "$id" >/dev/null || status=1
  done
  exit "$status"
}
trap cleanup EXIT
for name in "${names[@]}"; do
  id=$(podman create --name "$name" --pull never --network none --read-only --image-volume ignore \
    --memory 64m --cpus 1 --restart no --log-driver none --entrypoint /bin/sh \
    "$image" -c 'trap "exit 0" TERM; while :; do sleep 1 & wait $!; done')
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || exit 1
  ids+=("$id")
  podman start "$id" >/dev/null
done
for index in "${!names[@]}"; do
  [[ $(podman inspect --format '{{.Id}}' "${names[$index]}") == "${ids[$index]}" ]]
  [[ $(podman inspect --format '{{.State.Running}}' "${ids[$index]}") == true ]]
done
# Do not replace the helper or intercept Podman: exercise its real stop commands.
storage_stop_containers
for id in "${ids[@]}"; do
  [[ $(podman inspect --format '{{.State.Running}}' "$id") == false ]]
done
storage_stop_containers
echo 'Real Podman helper stopped all three disposable services; repeated shutdown passed.'
echo 'This does not exercise installed systemd timers, production admission or alerts.'
