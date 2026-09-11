#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config=deploy/otel-collector.yaml
compose=deploy/compose.yaml

for exporter in mlflow laminar; do
  grep -Eq "^  file_storage/${exporter}:" "$config"
  grep -Fq "storage: file_storage/${exporter}" "$config"
  grep -Fq "/var/lib/otelcol/storage/${exporter}" "$config"
  grep -Fq "/var/lib/otelcol/compaction/${exporter}" "$config"
done

grep -Fq 'fsync: true' "$config"
grep -Fq 'max_size: 134217728' "$config"
grep -Fq 'max_elapsed_time: 0s' "$config"
grep -Fq 'sizer: requests' "$config"
grep -Fq 'block_on_overflow: false' "$config"
grep -Fq 'extensions: [health_check, file_storage/mlflow, file_storage/laminar]' "$config"

init_block="$(sed -n '/^  otel-collector-storage-init:/,/^  otel-collector:/{p}' "$compose")"
grep -Fq 'user: "0:0"' <<<"$init_block"
grep -Fq 'restart: "no"' <<<"$init_block"
grep -Fq 'otel-collector-data:/var/lib/otelcol:rw' <<<"$init_block"
grep -Fq 'mkdir -p /var/lib/otelcol/storage/mlflow' <<<"$init_block"
grep -Fq 'chmod 0750 /var/lib/otelcol' <<<"$init_block"
grep -Fq 'chown 10001:10001 /var/lib/otelcol/storage/mlflow' <<<"$init_block"
grep -Fq 'cap_drop:' <<<"$init_block"
grep -Fq 'cap_add:' <<<"$init_block"
grep -Fq 'CHOWN' <<<"$init_block"
if grep -Fq 'FOWNER' <<<"$init_block"; then
  printf '%s\n' 'Storage initializer must not retain CAP_FOWNER.' >&2
  exit 1
fi

collector_block="$(sed -n '/^  otel-collector:/,/^  otel-collector-storage-init:/{p}' "$compose")"
grep -Fq 'otel-collector-storage-init:' <<<"$collector_block"
grep -Fq 'user: "10001:10001"' <<<"$collector_block"
grep -Fq 'cap_drop:' <<<"$collector_block"
grep -Fq 'otel-collector-data:/var/lib/otelcol:rw' <<<"$collector_block"
grep -Fq 'laminar-rabbitmq-data:/var/lib/rabbitmq' "$compose"
grep -Fq 'name: ai-agent-observability-otel-collector-data' "$compose"
grep -Fq 'name: ai-agent-observability-laminar-rabbitmq-data' "$compose"

if grep -Eq '(:13133:|published:.*13133)' "$compose"; then
  printf '%s\n' 'Collector health endpoint must remain container-private.' >&2
  exit 1
fi

case "${COLLECTOR_PERSISTENCE_RUNTIME:-skip}" in
  skip)
    printf '%s\n' 'Collector persistence runtime validation skipped (set COLLECTOR_PERSISTENCE_RUNTIME=1 or required).'
    ;;
  1|required)
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
      if [[ "${COLLECTOR_PERSISTENCE_RUNTIME}" == required ]]; then
        printf '%s\n' 'COLLECTOR_PERSISTENCE_RUNTIME=required needs a reachable Docker daemon' >&2
        exit 69
      fi
      printf '%s\n' 'Collector persistence runtime validation unavailable.'
      exit 0
    fi
    volume="ai-agent-observability-persistence-test-$$"
    cleanup() {
      docker volume rm "$volume" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT
    docker volume create "$volume" >/dev/null
    docker run --rm --network none --read-only --tmpfs /tmp --user 0:0 \
      --cap-drop=ALL --cap-add=CHOWN \
      --mount "type=volume,source=$volume,target=/var/lib/otelcol" \
      docker.io/library/alpine:3.22.1 /bin/sh -ec '
        mkdir -p /var/lib/otelcol/storage/mlflow /var/lib/otelcol/storage/laminar \
          /var/lib/otelcol/compaction/mlflow /var/lib/otelcol/compaction/laminar
        chmod 0750 /var/lib/otelcol /var/lib/otelcol/storage \
          /var/lib/otelcol/storage/mlflow /var/lib/otelcol/storage/laminar \
          /var/lib/otelcol/compaction /var/lib/otelcol/compaction/mlflow \
          /var/lib/otelcol/compaction/laminar
        chown 10001:10001 /var/lib/otelcol/storage/mlflow \
          /var/lib/otelcol/storage/laminar /var/lib/otelcol/compaction/mlflow \
          /var/lib/otelcol/compaction/laminar /var/lib/otelcol/storage \
          /var/lib/otelcol/compaction /var/lib/otelcol
      '
    docker run --rm --pull=never --network none --read-only --tmpfs /tmp \
      --user 10001:10001 --cap-drop=ALL \
      --mount "type=volume,source=$volume,target=/var/lib/otelcol" \
      docker.io/library/alpine:3.22.1 /bin/sh -ec '
        test "$(stat -c %u:%g:%a /var/lib/otelcol/storage/mlflow)" = 10001:10001:750
        test "$(stat -c %u:%g:%a /var/lib/otelcol/storage/laminar)" = 10001:10001:750
        test -w /var/lib/otelcol/storage/mlflow
        test -w /var/lib/otelcol/storage/laminar
      '
    docker run --rm --pull=missing --network none --read-only --tmpfs /tmp --user 10001:10001 \
      --cap-drop=ALL \
      --mount "type=bind,source=$repo_root/$config,target=/etc/otelcol-contrib/config.yaml,readonly" \
      --mount "type=volume,source=$volume,target=/var/lib/otelcol" \
      --env MLFLOW_EXPERIMENT_ID=0 \
      --env LAMINAR_PROJECT_API_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
      docker.io/otel/opentelemetry-collector-contrib:0.160.0 \
      validate --feature-gates=+extension.healthcheck.useComponentStatus \
      --config=/etc/otelcol-contrib/config.yaml
    printf '%s\n' 'Collector fresh-volume ownership and pinned-image config validation passed.'
    ;;
  *)
    printf '%s\n' 'COLLECTOR_PERSISTENCE_RUNTIME must be skip, 1, or required' >&2
    exit 64
    ;;
esac

printf '%s\n' 'Collector persistence source invariants passed.'
