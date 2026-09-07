# Recovery and storage operations

This guide covers the recovery boundary added for the Collector and the
stateful services in this Compose project. It is deliberately scoped to this
project's named volumes. It does not stop, remove, or restore any other
Compose project, host service, game installation, save, or provider profile.

## Collector recovery contract

The Collector has two persistent sending queues:

| Queue | Storage directory | Limit | Overflow behavior |
| --- | --- | --- | --- |
| MLflow exporter | `/var/lib/otelcol/storage/mlflow` | 1,024 requests; 128 MiB bbolt file cap | reject and account failed enqueue |
| Laminar exporter | `/var/lib/otelcol/storage/laminar` | 1,024 requests; 128 MiB bbolt file cap | reject and account failed enqueue |

Both queues use `file_storage`, `fsync: true`, and bounded compaction
directories on `otel-collector-data`. `max_elapsed_time: 0s` keeps retrying
until the queue drains or reaches a configured capacity/storage error. The
queues are not an acknowledgement boundary for the calling agent: a receiver
response means the Collector accepted data, not that either backend stored it.

The Collector process runs as UID/GID `10001:10001`, with a read-only root
filesystem and all Linux capabilities dropped. The one-shot
`otel-collector-storage-init` service is the only service intentionally
configured to run as root; it creates and chowns the exact queue directories
idempotently and never removes data.
If an operator intentionally replaces the Collector volume, remove only the
completed `ai-agent-observability-otel-collector-storage-init` container (after
confirming its exact name) before `up -d`, so the ownership initializer runs
again. Never remove a volume as a shortcut for repairing permissions.

The Collector starts after its storage initializer only. It does not depend on
MLflow, the Laminar dashboard, or the Laminar bootstrap service being healthy.
The health endpoint means that the Collector process and configuration are
ready (`http://127.0.0.1:13133/` by default); it does not mean either exporter
has a healthy backend. Inspect both metrics endpoints:

- `http://127.0.0.1:14319/metrics` — Collector internal metrics, including
  `otelcol_exporter_queue_capacity`, `otelcol_exporter_queue_size`,
  `otelcol_exporter_enqueue_failed_spans`,
  `otelcol_exporter_send_failed_spans`, and sent counters. The `normal`
  telemetry level keeps exporter and signal dimensions bounded and excludes
  detailed error dimensions.
- `http://127.0.0.1:14320/metrics` — filesystem usage for the Collector
  queue volume only. The filesystem receiver is filtered to
  `/var/lib/otelcol`; it does not mount or inspect the host filesystem.

If a backend is unavailable, `otelcol_exporter_send_failed_spans` and queue
depth show the outage while retries continue. If queue capacity or storage
capacity is exhausted, `otelcol_exporter_enqueue_failed_spans` records the
drop. Alert on queue depth, failed enqueue growth, and low filesystem
headroom; do not infer backend persistence from the Collector health endpoint.

## Named volume inventory

The Compose file owns these exact persistent volumes:

```text
ai-agent-observability-mlflow-postgres-data
ai-agent-observability-mlflow-storage-data
ai-agent-observability-laminar-postgres-data
ai-agent-observability-laminar-clickhouse-data
ai-agent-observability-laminar-clickhouse-logs
ai-agent-observability-laminar-quickwit-data
ai-agent-observability-laminar-rabbitmq-data
ai-agent-observability-otel-collector-data
```

The first seven preserve product metadata, artifacts, analytics, search data,
logs, and RabbitMQ ingest queues. The last preserves Collector queue records.
Container restart policies do not replace these volumes and do not provide a
consistent backup.

## Quiesced backup

Set `BACKUP_ROOT` to an operator-approved filesystem with enough free space.
The following procedure stops only this Compose project's containers, writes
one archive per named volume, records hashes, and restarts only containers that
were running before quiescence. It never uses `down -v` or `compose up` as a
backup recovery step. Require a preloaded, digest-pinned backup image containing
GNU tar (including ACL/xattr support); Alpine's default BusyBox tar does not
provide the archive flags below. Stage that image during approved installation,
not during recovery.

```bash
cd /opt/ai-agent-observability/deploy
backup_root="${BACKUP_ROOT:?set BACKUP_ROOT to an approved backup directory}/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup_root"
backup_image="${BACKUP_HELPER_IMAGE:?set a preloaded GNU tar image by sha256 digest}"
[[ "$backup_image" =~ @sha256:[0-9a-f]{64}$ ]] || exit 1
docker image inspect "$backup_image" >/dev/null
docker run --rm --pull=never --network none "$backup_image" tar --version
docker compose -p ai-agent-observability -f compose.yaml ps --status running --quiet \
  >"$backup_root/running-container-ids"

docker compose -p ai-agent-observability -f compose.yaml stop

for volume in \
  ai-agent-observability-mlflow-postgres-data \
  ai-agent-observability-mlflow-storage-data \
  ai-agent-observability-laminar-postgres-data \
  ai-agent-observability-laminar-clickhouse-data \
  ai-agent-observability-laminar-clickhouse-logs \
  ai-agent-observability-laminar-quickwit-data \
  ai-agent-observability-laminar-rabbitmq-data \
  ai-agent-observability-otel-collector-data; do
  docker volume inspect "$volume" >/dev/null
  docker run --rm --pull=never --network none \
    --mount "type=volume,source=$volume,target=/source,readonly" \
    --mount "type=bind,source=$backup_root,target=/backup" \
    "$backup_image" \
    tar --create --gzip --file "/backup/$volume.tar.gz" \
      --numeric-owner --xattrs --acls --directory /source .
done

(cd "$backup_root" && sha256sum ./*.tar.gz >SHA256SUMS)
mapfile -t previously_running <"$backup_root/running-container-ids"
if ((${#previously_running[@]})); then
  docker start "${previously_running[@]}"
fi
```

Record the backup timestamp, the checked-in Compose commit, image tags, and
the output of `docker compose ... config --images` with the hash file. Keep
the backup directory access restricted; it contains research data and may
contain sensitive trace payloads.

## Restore from a verified archive

Restore only after checking that the archive set came from one quiesced
snapshot and that the target volume names belong to this project. This
procedure intentionally clears the contents of each selected target volume
after hash verification; preserve the current volumes with the backup above
before proceeding. It does not delete or recreate volumes and it never touches
an unrelated volume.

Restore requires an operator-approved current start plan. It deliberately leaves
all containers stopped; restoring a historical snapshot must not revive a
container intentionally stopped since that snapshot. Do not use the backup's
old running-container list as current start authorization. Validate archives as
trusted operator-generated data before extraction, including paths, ownership,
links, and available disk space. An untrusted archive is not accepted input.

```bash
cd /opt/ai-agent-observability/deploy
backup_root="${BACKUP_ROOT:?set BACKUP_ROOT to the verified backup directory}"
backup_image="${BACKUP_HELPER_IMAGE:?set a preloaded GNU tar image by sha256 digest}"
[[ "$backup_image" =~ @sha256:[0-9a-f]{64}$ ]] || exit 1
docker image inspect "$backup_image" >/dev/null
docker run --rm --pull=never --network none "$backup_image" tar --version
(cd "$backup_root" && sha256sum -c SHA256SUMS)
docker compose -p ai-agent-observability -f compose.yaml stop

for volume in \
  ai-agent-observability-mlflow-postgres-data \
  ai-agent-observability-mlflow-storage-data \
  ai-agent-observability-laminar-postgres-data \
  ai-agent-observability-laminar-clickhouse-data \
  ai-agent-observability-laminar-clickhouse-logs \
  ai-agent-observability-laminar-quickwit-data \
  ai-agent-observability-laminar-rabbitmq-data \
  ai-agent-observability-otel-collector-data; do
  docker volume inspect "$volume" >/dev/null
  docker run --rm --pull=never --network none \
    --mount "type=volume,source=$volume,target=/source" \
    --mount "type=bind,source=$backup_root,target=/backup,readonly" \
    "$backup_image" sh -ec \
    "find /source -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar --extract --gzip --file /backup/$volume.tar.gz --numeric-owner --xattrs --acls --directory /source"
done

docker compose -p ai-agent-observability -f compose.yaml config --quiet
# Remain stopped. Start only exact containers from the current approved plan.
```

After restore, inspect service health, the Collector health endpoint, queue
metrics, and a newly generated non-sensitive smoke trace. Do not rerun a
bootstrap script merely to test recovery, regenerate `.env`, rotate an
existing deployment identity, or select a different image tag. If a restored
database or queue is corrupt or incompatible, stop and preserve it for
diagnosis; silently deleting state or creating a new identity is not recovery.

## Lifecycle and intentional stops

Compose owns long-lived container restart behavior (`unless-stopped`); the
systemd unit is a oneshot stack launcher and intentionally has no competing
`Restart=` directive. A deliberate `docker compose stop` or `docker stop`
remains stopped across engine restarts under this policy. An explicit
`docker compose up -d` or `systemctl start` is an operator request to start
the project again. Collector restart does not regenerate `.env` or require
the dashboards/bootstrap path.

These procedures provide source and synthetic recovery contracts. A Compose
parse, a container health response, or a queue file on disk is not live
telemetry-plane end-to-end evidence; verify backend receipt and retention
separately on an approved host.
