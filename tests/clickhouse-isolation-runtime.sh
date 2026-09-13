#!/usr/bin/env bash
# Root-only destructive fault injection inside newly allocated CI filesystems.
# Never run against a configured deployment. Requires an immutable local image.
set -euo pipefail
[[ ${CI:-} == true && $EUID == 0 && $# == 1 ]] || {
  echo 'Requires a disposable CI runner, root, and one local immutable image.' >&2; exit 77;
}
image=$1
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ || "$image" =~ @sha256:[0-9a-f]{64}$ ]] || exit 64
for command in podman mount umount mkfs.ext4 fallocate timeout; do
  command -v "$command" >/dev/null || exit 77
done
podman image exists "$image" || exit 77
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
name="obs-storage-runtime-$(basename "$work")"
flood_name="$name-flood"
mounted_data=0 mounted_logs=0
cleanup() {
  status=$?
  podman rm -f "$flood_name" >/dev/null 2>&1 || true
  podman rm -f "$name" >/dev/null 2>&1 || true
  if [[ $mounted_logs == 1 ]]; then umount "$work/logs" || status=1; fi
  if [[ $mounted_data == 1 ]]; then umount "$work/data" || status=1; fi
  # Never recurse into a mount that failed to detach.
  if ! mountpoint -q "$work/logs" && ! mountpoint -q "$work/data"; then
    rm -rf -- "$work"
  else
    echo "Disposable mounts retained for investigation: $work" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
mkdir "$work/data" "$work/logs"
# Real fixed allocations and ext4 exhaustion, not mocked df output or sparse disks.
# The production physical-device admission checker deliberately rejects these loops.
fallocate -l 1G "$work/data.img"
fallocate -l 64M "$work/logs.img"
mkfs.ext4 -q -F -m 0 -E nodiscard "$work/data.img"
mkfs.ext4 -q -F -m 0 -E nodiscard "$work/logs.img"
mount -o loop "$work/data.img" "$work/data"
mounted_data=1
mount -o loop "$work/logs.img" "$work/logs"
mounted_logs=1
mkdir "$work/data/clickhouse" "$work/logs/legacy-clickhouse"
start_server() {
  podman run -d --name "$name" --pull never --network none --read-only \
    --memory 4g --cpus 2 --ulimit core=0 --ulimit nofile=262144:262144 \
    --log-driver k8s-file --log-opt path="$work/logs/clickhouse.log" --log-opt max-size=512kb \
    --tmpfs /etc/clickhouse-server/users.d:rw,nosuid,nodev,size=1m,mode=0755 \
    --tmpfs /tmp:rw,nosuid,nodev,size=64m,mode=1777 \
    --tmpfs /run:rw,nosuid,nodev,size=8m,mode=0755 \
    -v "$work/data/clickhouse:/var/lib/clickhouse:rw" \
    -v "$work/logs/legacy-clickhouse:/var/log/clickhouse-server:ro" \
    -v "$repo_root/deploy/laminar/clickhouse-server-config.xml:/etc/clickhouse-server/config.d/ai-agent-observability.xml:ro" \
    -v "$repo_root/deploy/laminar/clickhouse-profiles-config.xml:/etc/clickhouse-server/users.d/ai-agent-observability.xml:ro" \
    -e CLICKHOUSE_USER=storage_test -e CLICKHOUSE_PASSWORD=disposable-test-only \
    "$image" >/dev/null
}
query() {
  timeout 30s podman exec "$name" clickhouse-client --user storage_test \
    --password disposable-test-only --query "$1"
}
wait_ready() {
  local deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    if timeout 3s podman exec "$name" clickhouse-client --user storage_test \
      --password disposable-test-only --query 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    [[ $(podman inspect --format '{{.State.Running}}' "$name") == true ]] || break
    sleep 2
  done
  tail -c 32768 "$work/logs/clickhouse.log" >&2 || true
  return 1
}
start_server
wait_ready
[[ $(query 'SELECT version()') == 26.5.7.64 ]]
[[ $(query 'SELECT currentUser()') == storage_test ]]
[[ $(query "SELECT value FROM system.settings WHERE name='date_time_input_format'") == best_effort ]]
if podman exec "$name" sh -c 'touch /unexpected-writable-root' 2>/dev/null; then
  echo 'Image root is writable.' >&2; exit 1
fi
query 'CREATE TABLE default.storage_acceptance (id UInt64) ENGINE=MergeTree ORDER BY id'
query 'INSERT INTO default.storage_acceptance VALUES (1)'

# Exhaust data with a private filler. An insert requiring new part space must fail
# while the old row remains readable; release only the filler, then prove recovery.
available=$(df -B1 --output=avail "$work/data" | tail -1 | tr -d ' ')
fallocate -l "$((available - 1048576))" "$work/data/test-filler"
if query 'INSERT INTO default.storage_acceptance SELECT rand64() FROM numbers(2000000)' >"$work/full-insert.out" 2>&1; then
  echo 'Expected allocation exhaustion to reject the large insert.' >&2; exit 1
fi
if ! grep -Eq 'NOT_ENOUGH_SPACE|No space left on device' "$work/full-insert.out"; then
  cat "$work/full-insert.out" >&2
  echo 'Insert failed without evidence of storage exhaustion.' >&2; exit 1
fi
[[ $(query 'SELECT count() FROM default.storage_acceptance') == 1 ]]
rm -- "$work/data/test-filler"
query 'INSERT INTO default.storage_acceptance VALUES (2)'

# Exhaust the diagnostic allocation independently and measure its hard ceiling.
# A failed logger must not gain a writable image root or a new host-log route.
mkdir "$work/control"
podman run -d --name "$flood_name" --pull never --network none --read-only \
  --memory 128m --cpus 1 --restart no --entrypoint /bin/bash \
  --log-driver k8s-file --log-opt path="$work/logs/flood.log" --log-opt max-size=512kb \
  -v "$work/control:/control:rw" "$image" -ec \
  'printf "READY\n"; while [[ ! -e /control/go ]]; do sleep 0.1; done; touch /control/attempted; for ((i=0;i<60000;i++)); do printf "full-sink-test-%0100d\n" "$i"; done; touch /control/done; sleep 30' >/dev/null
ready=0
for ((attempt=0;attempt<50;attempt++)); do
  if grep -q READY "$work/logs/flood.log" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[[ $ready == 1 ]] || { echo 'Full-sink writer did not establish its normal log route.' >&2; exit 1; }
conmon_pid=$(podman inspect --format '{{.State.ConmonPid}}' "$flood_name")
[[ "$conmon_pid" =~ ^[1-9][0-9]*$ ]]
flood_start=$(date +%s)
if dd if=/dev/zero of="$work/logs/test-filler" bs=4096 status=none 2>"$work/full-log.out"; then
  echo 'Expected the diagnostic filesystem to run out of space.' >&2; exit 1
fi
available=$(df -B1 --output=avail "$work/logs" | tail -1 | tr -d ' ')
((available <= 4096))
touch "$work/control/go"
finished=0
for ((attempt=0;attempt<30;attempt++)); do
  used=$(df -B1 --output=used "$work/logs" | tail -1 | tr -d ' ')
  ((used <= 67108864))
  if [[ -e "$work/control/done" ]] || [[ $(podman inspect --format '{{.State.Running}}' "$flood_name") == false ]]; then
    finished=1; break
  fi
  sleep 1
done
[[ $finished == 1 && -e "$work/control/attempted" ]] || {
  echo 'Writer never attempted the full sink or did not finish within its bounded window.' >&2; exit 1;
}
timeout 15s podman stop --time 5 "$flood_name" >/dev/null
# Observe this conmon process only; never copy unrelated runner journal contents.
if command -v journalctl >/dev/null; then
  journal_bytes=$(journalctl --since "@$flood_start" "_PID=$conmon_pid" --no-pager -o cat 2>/dev/null | wc -c)
  printf 'Full-sink conmon journal output: %s bytes during the finite flood.\n' "$journal_bytes"
  ((journal_bytes <= 2097152)) || { echo 'Full-sink runtime diagnostics exceeded the 2MiB test bound.' >&2; exit 1; }
else
  echo 'journalctl is required to observe alternate runtime diagnostics.' >&2; exit 77
fi
[[ $(podman inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$name") == true ]]
query 'SELECT count() FROM default.storage_acceptance' >"$work/count.out"
[[ $(cat "$work/count.out") == 2 ]]
used=$(df -B1 --output=used "$work/logs" | tail -1 | tr -d ' ')
((used <= 67108864))
rm -- "$work/logs/test-filler"
timeout 75s podman stop --time 60 "$name" >/dev/null
podman rm "$name" >/dev/null
start_server
wait_ready
[[ $(query 'SELECT groupArray(id) FROM (SELECT id FROM default.storage_acceptance ORDER BY id)') == '[1,2]' ]]
echo 'Exact-version read-only startup, account/profile settings, full data rejection, full-sink flood, log allocation ceiling and row persistence passed.'
echo 'CLI runtime evidence only: production admission, host log forwarding, full ingestion, alerts and migration remain separate gates.'
