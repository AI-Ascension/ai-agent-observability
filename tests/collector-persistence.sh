#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_config="$repo_root/tests/config/collector-persistence-source.yaml"
sink_config="$repo_root/tests/config/collector-persistence-sink.yaml"
collector_image=docker.io/otel/opentelemetry-collector-contrib:0.160.0
runtime_test="${COLLECTOR_PERSISTENCE_RUNTIME:-skip}"

grep -Fq 'storage: file_storage' "$source_config"
grep -Fq 'fsync: true' "$source_config"
grep -Fq 'queue_size: 8' "$source_config"
grep -Fq 'max_elapsed_time: 0s' "$source_config"

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

test_root="$(mktemp -d)"
network_name="ai-agent-observability-pq-${PPID}-${BASHPID:-$$}"
source_name="${network_name}-source"
sink_name="${network_name}-sink"
cleanup() {
  docker rm -f "$source_name" >/dev/null 2>&1 || true
  docker rm -f "$sink_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  rm -r -- "$test_root"
}
trap cleanup EXIT

mkdir "$test_root/storage"
# This bind mount is test-only. Production Compose uses the root-owned named
# volume and its one-shot ownership initializer instead.
chmod 0777 "$test_root/storage"
docker network create --internal "$network_name" >/dev/null

docker run -d --name "$source_name" --network "$network_name" \
  --publish 127.0.0.1::4318 \
  --publish 127.0.0.1::8888 \
  --mount "type=bind,source=$source_config,target=/etc/otelcol-contrib/config.yaml,readonly" \
  --mount "type=bind,source=$test_root/storage,target=/var/lib/otelcol" \
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

# ExportTraceServiceRequest containing one span named synthetic-persistent-
# queue. It is intentionally sent while the sink container is absent.
payload="$test_root/trace.pb"
printf '%s' \
  '0a3c123a12380a1001010101010101010101010101010101120802020202020202022a1a73796e7468657469632d70657273697374656e6e742d7175657565' \
  | xxd -r -p >"$payload"
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
curl --fail --silent --show-error \
  -H 'Content-Type: application/x-protobuf' \
  --data-binary "@$payload" "http://127.0.0.1:$source_port/v1/traces" >/dev/null

# The queue file is created during Collector startup. Require the queue-depth
# metric to reach one so this assertion covers the submitted span, not just
# storage initialization.
queue_depth=0
for _ in {1..30}; do
  if curl --fail --silent "http://127.0.0.1:$source_metrics_port/metrics" \
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

queue_file=
for _ in {1..30}; do
  queue_file="$(find "$test_root/storage" -type f -size +0c -print -quit)"
  if [[ -n "$queue_file" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "$queue_file" ]]; then
  docker logs --tail=80 "$source_name" >&2 || true
  printf '%s\n' 'source Collector did not persist a queue record before restart' >&2
  exit 1
fi

docker kill "$source_name" >/dev/null
docker rm "$source_name" >/dev/null

# Reopen the same storage directory before starting the sink. A receipt from
# the sink proves that the span was read from disk after process replacement.
docker run -d --name "$source_name" --network "$network_name" \
  --publish 127.0.0.1::8888 \
  --mount "type=bind,source=$source_config,target=/etc/otelcol-contrib/config.yaml,readonly" \
  --mount "type=bind,source=$test_root/storage,target=/var/lib/otelcol" \
  "$collector_image" --config=/etc/otelcol-contrib/config.yaml >/dev/null
docker run -d --name "$sink_name" --network "$network_name" \
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
