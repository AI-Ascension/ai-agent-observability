#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

collector_config=deploy/otel-collector.yaml
compose_file=deploy/compose.yaml

# Static contract checks cover the parts that must remain true even when no
# container runtime is available. Runtime validation is opt-in below because
# it may pull the pinned Collector image.
for extension in health_check file_storage/mlflow file_storage/laminar; do
  grep -Eq "^  ${extension//\//\\/}:" "$collector_config"
  grep -Fq "$extension" "$collector_config"
done

for queue in mlflow laminar; do
  grep -Fq "storage: file_storage/$queue" "$collector_config"
done

grep -Fq 'fsync: true' "$collector_config"
grep -Fq 'max_size: 134217728' "$collector_config"
grep -Fq 'queue_size: 1024' "$collector_config"
grep -Fq 'sizer: requests' "$collector_config"
grep -Fq 'block_on_overflow: false' "$collector_config"
grep -Fq 'max_elapsed_time: 0s' "$collector_config"
if grep -Fq 'persistent_storage_enabled' "$collector_config"; then
  printf '%s\n' 'legacy in-memory persistent queue setting is not accepted' >&2
  exit 1
fi

for metric in \
  otelcol_exporter_queue_capacity \
  otelcol_exporter_queue_size \
  otelcol_exporter_enqueue_failed_spans \
  otelcol_exporter_send_failed_spans; do
  # These names are emitted by the pinned Collector's normal telemetry level;
  # keep the list in this test as an accounting contract for operators.
  grep -Fq "$metric" docs/RECOVERY.md
done
grep -Fq 'level: normal' "$collector_config"
grep -Fq 'port: 8888' "$collector_config"
grep -Fq 'hostmetrics/storage' "$collector_config"
grep -Fq 'prometheus/storage' "$collector_config"
grep -Fq 'endpoint: 0.0.0.0:8889' "$collector_config"

collector_block="$(sed -n '/^  otel-collector:/,/^volumes:/p' "$compose_file")"
grep -Fq 'user: "10001:10001"' <<<"$collector_block"
grep -Fq 'read_only: true' <<<"$collector_block"
grep -Fq 'cap_drop:' <<<"$collector_block"
grep -Fq 'otel-collector-data:/var/lib/otelcol:rw' <<<"$collector_block"
if grep -Eq 'mlflow:|laminar-bootstrap:' <<<"$collector_block"; then
  printf '%s\n' 'Collector startup is coupled to a dashboard/bootstrap dependency' >&2
  exit 1
fi

storage_init_block="$(sed -n '/^  otel-collector-storage-init:/,/^  otel-collector:/p' "$compose_file")"
grep -Fq 'user: "0:0"' <<<"$storage_init_block"
grep -Fq 'restart: "no"' <<<"$storage_init_block"
grep -Fq 'install -d -m 0750 -o 10001 -g 10001' <<<"$storage_init_block"

if grep -Eq '^Restart=' systemd/ai-agent-observability.service; then
  printf '%s\n' 'systemd must not add a second container restart-policy owner' >&2
  exit 1
fi

runtime_validate="${COLLECTOR_RUNTIME_VALIDATE:-skip}"
case "$runtime_validate" in
  skip)
    printf '%s\n' 'Collector static invariants passed; runtime config validation skipped (set COLLECTOR_RUNTIME_VALIDATE=1).'
    ;;
  1|required)
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
      if [[ "$runtime_validate" == required ]]; then
        printf '%s\n' 'COLLECTOR_RUNTIME_VALIDATE=required needs a reachable Docker daemon' >&2
        exit 69
      fi
      printf '%s\n' 'Collector static invariants passed; runtime config validation unavailable.'
      exit 0
    fi
    runtime_root="$(mktemp -d)"
    container_name="ai-agent-observability-config-check-$$"
    cleanup() {
      docker rm -f "$container_name" >/dev/null 2>&1 || true
      rm -r -- "$runtime_root"
    }
    trap cleanup EXIT
    chmod 0777 "$runtime_root"
    docker run --rm --name "$container_name" \
      --user 10001:10001 \
      --mount "type=bind,source=$repo_root/$collector_config,target=/etc/otelcol-contrib/config.yaml,readonly" \
      --mount "type=bind,source=$runtime_root,target=/var/lib/otelcol" \
      --env MLFLOW_EXPERIMENT_ID=0 \
      --env LAMINAR_PROJECT_API_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
      docker.io/otel/opentelemetry-collector-contrib:0.160.0 \
      validate --config=/etc/otelcol-contrib/config.yaml
    printf '%s\n' 'Collector pinned-image config validation passed.'
    ;;
  *)
    printf '%s\n' 'COLLECTOR_RUNTIME_VALIDATE must be skip, 1, or required' >&2
    exit 64
    ;;
esac
