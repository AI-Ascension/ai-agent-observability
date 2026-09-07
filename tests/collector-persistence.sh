#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_config="$repo_root/tests/config/collector-persistence-source.yaml"
sink_config="$repo_root/tests/config/collector-persistence-sink.yaml"
payload="$repo_root/tests/config/collector-persistence-trace.json"
collector_image=docker.io/otel/opentelemetry-collector-contrib:0.160.0
runtime_test="${COLLECTOR_PERSISTENCE_RUNTIME:-skip}"

grep -Fq 'storage: file_storage' "$source_config"
grep -Fq 'fsync: true' "$source_config"
grep -Fq 'queue_size: 8' "$source_config"
grep -Fq 'max_elapsed_time: 0s' "$source_config"
jq -e '.resourceSpans[0].scopeSpans[0].spans[0] |
  .name == "synthetic-persistent-queue" and
  (.traceId | test("^[0-9a-f]{32}$")) and
  (.spanId | test("^[0-9a-f]{16}$")) and
  (.startTimeUnixNano | test("^[0-9]+$")) and
  (.endTimeUnixNano | test("^[0-9]+$"))' "$payload" >/dev/null

case "$runtime_test" in
  skip)
    printf '%s\n' 'Collector persistence fixture passed; runtime persistence test skipped (set COLLECTOR_PERSISTENCE_RUNTIME=1).'
    exit 0
    ;;
  1|required)
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
      if [[ "$runtime_test" == required ]]; then
        printf '%s\n' 'COLLECTOR_PERSISTENCE_RUNTIME=required needs a reachable Docker daemon' >&2
        exit 69
      fi
      printf '%s\n' 'Collector persistence fixture passed; runtime persistence test unavailable.'
      exit 0
    fi
    ;;
  *)
    printf '%s\n' 'COLLECTOR_PERSISTENCE_RUNTIME must be skip, 1, or required' >&2
    exit 64
    ;;
esac

network_name="ai-agent-observability-pq-${PPID}-${BASHPID:-$$}"
source_name="${network_name}-source"
sink_name="${network_name}-sink"
storage_volume="${network_name}-storage"
cleanup() {
  local original_status=$?
  if ((original_status != 0)); then
    docker logs --tail=80 "$source_name" >&2 || true
    docker logs --tail=80 "$sink_name" >&2 || true
  fi
  docker rm -f "$source_name" >/dev/null 2>&1 || true
  docker rm -f "$sink_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  docker volume rm "$storage_volume" >/dev/null 2>&1 || true
  return "$original_status"
}
trap cleanup EXIT

# This uniquely named volume contains synthetic fixture data only. Keeping it
# in the container runtime avoids leaving UID-10001 files in a host temp tree.
docker volume create "$storage_volume" >/dev/null
docker network create --internal "$network_name" >/dev/null

docker run -d --name "$source_name" --network "$network_name" \
  --publish 127.0.0.1::4318 \
  --publish 127.0.0.1::8888 \
  --mount "type=bind,source=$source_config,target=/etc/otelcol-contrib/config.yaml,readonly" \
  --mount "type=volume,source=$storage_volume,target=/var/lib/otelcol" \
  "$collector_image" --config=/etc/otelcol-contrib/config.yaml >/dev/null

for _ in {1..30}; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$source_name" 2>/dev/null || true)" == true ]]; then
    break
  fi
  sleep 1
done
if [[ "$(docker inspect -f '{{.State.Running}}' "$source_name" 2>/dev/null || true)" != true ]]; then
  docker logs --tail=80 "$source_name" >&2 || true
  printf '%s\n' 'source Collector did not remain running' >&2
  exit 1
fi

# OTLP JSON ExportTraceServiceRequest, sent while the sink is absent.
# Keep the readable fixture validated above rather than hand-encoding protobuf
# field lengths; malformed payloads must not masquerade as a queue test.
source_port="$(docker port "$source_name" 4318/tcp 2>/dev/null | awk -F: 'NR == 1 { print $NF }')"
if [[ -z "$source_port" ]]; then
  printf '%s\n' 'source Collector port was not published' >&2
  exit 1
fi
source_metrics_port="$(docker port "$source_name" 8888/tcp 2>/dev/null | awk -F: 'NR == 1 { print $NF }')"
if [[ -z "$source_metrics_port" ]]; then
  printf '%s\n' 'source Collector metrics port was not published' >&2
  exit 1
fi
# Running state is not listener readiness. Poll without sending telemetry.
listener_ready=0
for _ in {1..30}; do
  if curl --silent --output /dev/null --connect-timeout 1 --max-time 2 \
      "http://127.0.0.1:$source_port/v1/traces"; then
    listener_ready=1
    break
  fi
  sleep 1
done
if [[ "$listener_ready" != 1 ]]; then
  printf '%s\n' 'source Collector listener never became available' >&2
  exit 1
fi
curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  -H 'Content-Type: application/json' \
  --data-binary "@$payload" "http://127.0.0.1:$source_port/v1/traces" >/dev/null

# The queue file is created during Collector startup. Require the queue-depth
# metric to reach one so this assertion covers the submitted span, not just
# storage initialization.
queue_depth=0
for _ in {1..30}; do
  if curl --fail --silent --connect-timeout 2 --max-time 5 "http://127.0.0.1:$source_metrics_port/metrics" \
      | grep -Eq 'otelcol_exporter_queue_size\{[^}]*\} [1-9]'; then
    queue_depth=1
    break
  fi
  sleep 1
done
if [[ "$queue_depth" != 1 ]]; then
  docker logs --tail=80 "$source_name" >&2 || true
  printf '%s\n' 'source Collector queue depth did not reflect the submitted span' >&2
  exit 1
fi

docker kill "$source_name" >/dev/null
docker rm "$source_name" >/dev/null

# Reopen the same storage directory before starting the sink. A receipt from
# the sink proves that the span was read from disk after process replacement.
docker run -d --name "$source_name" --network "$network_name" \
  --publish 127.0.0.1::8888 \
  --mount "type=bind,source=$source_config,target=/etc/otelcol-contrib/config.yaml,readonly" \
  --mount "type=volume,source=$storage_volume,target=/var/lib/otelcol" \
  "$collector_image" --config=/etc/otelcol-contrib/config.yaml >/dev/null
docker run -d --name "$sink_name" --network "$network_name" --network-alias sink \
  --mount "type=bind,source=$sink_config,target=/etc/otelcol-contrib/config.yaml,readonly" \
  "$collector_image" --config=/etc/otelcol-contrib/config.yaml >/dev/null

for _ in {1..45}; do
  if docker logs --tail=200 "$sink_name" 2>&1 | grep -Fq 'synthetic-persistent-queue'; then
    printf '%s\n' 'Collector persistent queue survived process replacement and was received by the delayed sink.'
    exit 0
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$source_name" 2>/dev/null || true)" != true ]]; then
    docker logs --tail=80 "$source_name" >&2 || true
    printf '%s\n' 'replacement source Collector exited before queue delivery' >&2
    exit 1
  fi
  sleep 1
done

docker logs --tail=80 "$source_name" >&2 || true
docker logs --tail=80 "$sink_name" >&2 || true
printf '%s\n' 'delayed sink did not receive the persisted span' >&2
exit 1
