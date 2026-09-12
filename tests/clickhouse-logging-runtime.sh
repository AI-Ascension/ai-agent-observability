#!/usr/bin/env bash
# Disposable runtime test; does not touch production containers, networks or volumes.
# Exit 77 = unavailable, not passed. Supply an already present exact image ID/digest.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: clickhouse-logging-runtime.sh IMAGE_ID_OR_DIGEST' >&2; exit 64; }
image=$1
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ || "$image" =~ @sha256:[0-9a-f]{64}$ ]] || {
  echo 'Require immutable local image ID or digest.' >&2; exit 64;
}
command -v podman >/dev/null || exit 77
podman image exists "$image" || exit 77
version=$(podman run --rm --network none --memory 512m --cpus 1 --pull never \
  --log-driver none --entrypoint clickhouse "$image" --version)
printf '%s\n' "$version"
[[ "$version" == *'version 26.5.7.64 '* ]] || {
  echo 'Runtime acceptance requires the incident image version 26.5.7.64.' >&2; exit 77;
}
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
chmod 700 "$test_dir"
name="obs-clickhouse-logging-test-$(basename "$test_dir")"
cleanup() {
  podman rm -f "$name" >/dev/null 2>&1 || true
  # Only this test's mktemp directory is removed. Keep on failure for diagnosis.
  if [[ ${passed:-0} == 1 ]]; then rm -rf -- "$test_dir"; else echo "Evidence retained: $test_dir" >&2; fi
}
trap cleanup EXIT
config="$repo_root/deploy/laminar/clickhouse-server-config.xml"
# Native config processing covers inherited/merged log settings, unlike XML grep.
for key in logger.log logger.errorlog; do
  output=$(podman run --rm --network none --memory 512m --cpus 1 --pull never \
    --log-driver none --entrypoint clickhouse \
    -v "$config:/etc/clickhouse-server/config.d/ai-agent-observability.xml:ro" \
    "$image" extract-from-config --config-file /etc/clickhouse-server/config.xml --key "$key" --try)
  [[ -z "$output" ]] || { echo "Unexpected file sink: $key" >&2; exit 1; }
done
output=$(podman run --rm --network none --memory 512m --cpus 1 --pull never \
  --log-driver none --entrypoint clickhouse \
  -v "$config:/etc/clickhouse-server/config.d/ai-agent-observability.xml:ro" \
  "$image" extract-from-config --config-file /etc/clickhouse-server/config.xml --key logger.console)
[[ "$output" == 1 ]]
# Exercise the actual conmon capture path with repeated lines and one large message.
# The finite writer emits ~8MiB, then stays alive for log inspection.
podman run -d --name "$name" --network none --memory 128m --cpus 1 --pull never \
  --read-only --log-driver k8s-file --log-opt path="$test_dir/console.log" \
  --log-opt max-size=512kb --entrypoint /bin/bash "$image" -ec \
  'for ((i=0;i<60000;i++)); do printf "storage-containment-test-%0100d\n" "$i"; done; head -c 1048576 /dev/zero | tr "\0" x; printf "\nCOMPLETE\n"; sleep 60' >/dev/null
complete=0
for ((attempt=0;attempt<60;attempt++)); do
  if [[ -f "$test_dir/console.log" ]] && tail -c 4096 "$test_dir/console.log" | grep -q COMPLETE; then complete=1; break; fi
  [[ $(podman inspect --format '{{.State.Running}}' "$name") == true ]] || break
  sleep 1
done
[[ $complete == 1 ]] || { echo 'Flood did not complete.' >&2; exit 1; }
bytes=$(stat -c %s "$test_dir/console.log")
# Permit one bounded oversized record; report it instead of promising an exact cap.
((bytes <= 2097152)) || { echo "Unbounded capture: $bytes bytes" >&2; exit 1; }
printf 'Native file sinks absent; console enabled; finite flood retained %s bytes (512KB configured; <=2MiB test bound).\n' "$bytes"
echo 'This tests log-driver behavior, not a hard filesystem quota or full server/ingestion acceptance.'
passed=1
