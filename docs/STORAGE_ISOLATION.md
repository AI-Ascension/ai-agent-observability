# ClickHouse storage isolation — implementation candidate

Tracking: issue #28. Owner: deployment/storage lane. Runtime review is independent
of the source implementation. No host rollout or data migration is claimed here.

## Log containment

The default ClickHouse XML now replaces the inherited logger with console logging at
information level, removes both file sinks, and disables direct syslog. Existing
research and system-table retention is unchanged. Existing log volumes are preserved.
This source change alone does **not** bound console capture on the default Compose
deployment: the Podman-specific override supplies the bounded capture route.

`deploy/compose.storage-isolation.yaml` switches only ClickHouse's writable data to
an admitted bind mount, captures diagnostics with `k8s-file` at a configured 50MB
limit, disables automatic container restart, makes the image root read-only and
uses bounded temporary filesystems for entrypoint-generated account configuration,
temporary process files and runtime files. Core dumps are disabled for this container.
The legacy log mount is read-only. Account/password values and profile settings remain
under the existing deployment's credential flow. Verify all effective grants and
image entrypoint behavior before cutover; this overlay has not yet passed live startup.

Use this only after the operator has provisioned and admitted `OBS_DATA_ROOT` and
`OBS_DIAGNOSTIC_ROOT` and migrated the data consistently. Both must be canonical mount
roots with enforced allocation limits, not newly created ordinary directories.
Pre-create `clickhouse` and `legacy-clickhouse` within the respective mounts with the
verified service ownership. `create_host_path: false` prevents accidental directory
creation but is not a replacement for mount-identity admission.

Start from `deploy/storage/storage.example.tsv`; it deliberately refuses admission
until all identity and measured-budget placeholders are replaced. The current checker
supports fixed physical disks/partitions and rejects loop/device-mapper ancestry.
It verifies exact mountpoint, filesystem UUID, device identity, read-write status,
byte/inode ceilings and combined free-space floors/reserves. Other quota backends
require their own verified admission implementation; none is claimed by this candidate.

Render with the target environment without printing the rendered secrets:

```bash
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.storage-isolation.yaml config --quiet
```

Do not apply this example directly to a running deployment. Include both Compose
files in the reviewed startup lifecycle and require mount admission before `up`.
The initializer includes the overlay only when `OBS_STORAGE_ISOLATION=1`, requiring
the reviewed rootful Podman API and `OBS_STORAGE_MANIFEST`. It checks the persistent
stop latch and runs mount admission before invoking Compose. Container restart `no`
does not prevent an explicit Compose start or host boot orchestration that omits this
gate. Manual direct starts are outside the admitted workflow.

The candidate `systemd/ai-agent-observability-storage.conf` boot drop-in requires the
two mounted filesystems and enables that gate. Adapt its paths to the admitted roots.
The separate storage timer runs `stop-on-pressure.sh` independently of database health.
It latches admission failures, stops Collector first, Laminar ingest next, and then
ClickHouse. It retries failed stops and never restarts a container automatically.
Collector shutdown also interrupts delivery to MLflow: preserve and reconcile its
queues, notify producers of the maintenance boundary and account for rejected spans.
Container stop has a 60-second grace period and may terminate forcibly after it; this
is an emergency containment policy, not a consistent backup procedure. Its external
alert integration and runtime stop behavior remain unverified.

Install the manifest and scripts with root ownership and no untrusted writable parent
directories. Keep the small latch under `/var/lib/ai-agent-observability/storage-isolation`.
After an incident, inspect all mounts and reconcile accepted records before manually
removing that exact latch. Removing it does not start a service. Re-run admission and
start through the managed lifecycle; do not remove it merely to silence an error.

## Capacity and migration gate

Prefer dedicated physical observability storage. Data sizing must include actual
retained bytes/day, owner-required retention, bursts and merge/mutation temporary
space. A fixed block allocation is an interim capacity boundary only if backed by
reserved non-thin capacity. A named volume or sparse file has no such guarantee.
The diagnostic budget is provisionally 1GiB; the 50MB per-file setting is operational
log retention, not an aggregate hard quota. Runtime tests must measure oversized
records and any rotation overshoot.

Before migration, use `deploy/storage/inspect-clickhouse.sh` through normal admin
access. It reports selected metadata and effective logger keys, never environments,
credentials or table contents. A container file-access error does not by itself prove
a missing directory. Inspect ownership and rotation permissions inside its namespace.
Record the exact image digest and source hashes; the current floating release tag
must not cause an incidental upgrade during this incident.

Quiesce the actual producers and the Laminar ingest workers, accounting for the
Collector's acknowledgement and queue semantics. Existing accepted records must
remain backed up or demonstrably delivered. Preserve a consistent backup outside the
live allocation, migrate while writes are quiesced, verify rows and grants, then admit
new ingestion. Preserve the original named volume. Rollback after new writes requires
reconciliation or reverse migration; reverting to an old copy loses those writes.

## Other storage paths remain part of acceptance

The ClickHouse override does not claim to isolate the entire observability plane.
RabbitMQ and Collector queues, PostgreSQL, Quickwit, artifact stores, image storage,
host journald, rsyslog and runtime diagnostics all require measured allocation and
route review. Do not silently increase upstream queues or allow retries to fill root.
Journal `SystemMaxUse` does not cap rsyslog's files. Confirm duplicate forwarding and
apply a reviewed, service-scoped route; do not discard unrelated host diagnostics.

Research-retention changes require a decision. TTL is merge-based housekeeping and
does not replace quotas. Plan warning at 70%, admission stop at 85% or the measured
merge reserve, whichever is earlier, plus time-to-exhaustion alerts. A critical stop
must latch until capacity and identity are revalidated. The monitoring path must work
when ClickHouse is unavailable, and service-stop failures must be visible.

## Validation

`tests/clickhouse-logging-runtime.sh IMAGE_ID_OR_DIGEST` uses a pre-existing immutable
image in disposable Podman containers. It checks effective native logger keys and a
finite ~8MiB console flood with a large record. It creates no production volumes and
does not connect to production networks. Exit 77 means unavailable, never success.
Its per-file assertion allows bounded overshoot; it is not a hard-filesystem-quota
test, ingestion test, or production acceptance.

Still required: real quota-backed disposable tests for full data/log allocations,
mount loss and no fallback, pressure-stop/latch/restart, alert delivery, complete
server startup and authenticated ingestion, data migration/rollback, 30–60 minute
normal-load observation and coordinated reboot persistence. Keep Windows domain
state distinct from its latched block-error status. An in-guest reboot need not
restart QEMU. Do not reopen/repair an active backing chain to hide the error.

References:
- https://docs.podman.io/en/v4.9.3/markdown/podman-run.1.html
- https://raw.githubusercontent.com/ClickHouse/ClickHouse/v26.5.7.64-stable/docker/server/entrypoint.sh
- https://raw.githubusercontent.com/ClickHouse/ClickHouse/v26.5.7.64-stable/programs/server/config.xml
- https://www.freedesktop.org/software/systemd/man/252/journald.conf.html
- https://clickhouse.com/docs/concepts/features/operations/delete/ttl
