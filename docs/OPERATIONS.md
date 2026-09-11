# Operations

## First deployment on a Podman host

Copy the repository to a dedicated directory on the target host, then run the
initializer as the account that owns the deployment directory. The unit and the
commands below use `/opt/ai-agent-observability`; if you install elsewhere,
leave the checked-in unit unchanged and override its paths with the drop-in
described under [Install boot orchestration](#install-boot-orchestration). Do
not commit a host account path back to this repository. For the rootful/system
Podman convention used by the Train domain, the command is:

```bash
cd /opt/ai-agent-observability/deploy
sudo env DOCKER_HOST=unix:///run/podman/podman.sock COMPOSE_ENGINE=docker ./init.sh
```

The initializer creates `.env` with mode `0600`, validates the Compose model,
builds the two wrapper images, and starts only the services in this project.
It never overwrites an existing `.env`. Keep the generated file on the target
host; do not copy it into Git, CI, or chat.

If a normal Docker daemon is intentionally used, omit `sudo` and
`DOCKER_HOST`. If rootless Podman is intentionally used, run with
`COMPOSE_ENGINE=podman` and use the account's own Podman storage.

## Install boot orchestration

After the first successful start, install the checked-in systemd unit:

```bash
sudo install -m 0644 ../systemd/ai-agent-observability.service \
  /etc/systemd/system/ai-agent-observability.service
sudo systemctl daemon-reload
sudo systemctl enable --now ai-agent-observability.service
```

The unit uses the rootful Podman API socket, an explicit project name, and
`--no-build` on boot. Builds and upgrades remain deliberate operator actions.

The unit's `WorkingDirectory` and `ExecStart` default to
`/opt/ai-agent-observability/deploy`. For any other deployment directory, leave
the checked-in unit unchanged and override both paths with a drop-in:

```bash
sudo systemctl edit ai-agent-observability.service
```

```ini
[Service]
WorkingDirectory=<deployment-dir>/deploy
ExecStart=
ExecStart=<deployment-dir>/deploy/init.sh
```

The empty `ExecStart=` line clears the checked-in command before the override
adds its own; without it the `oneshot` unit would run both. `systemctl edit`
reloads the manager after saving, so re-run only `systemctl enable --now`.

## Inspection without secret output

```bash
cd /opt/ai-agent-observability/deploy
sudo env DOCKER_HOST=unix:///run/podman/podman.sock \
  docker compose -p ai-agent-observability -f compose.yaml ps
sudo podman ps --filter name=ai-agent-observability --format '{{.Names}}|{{.Status}}|{{.Ports}}'
sudo systemctl status ai-agent-observability.service --no-pager
```

Health probes are intentionally bounded to loopback:

```bash
curl -fsS http://127.0.0.1:15000/health
curl -fsS http://127.0.0.1:18000/health
curl -fsS http://127.0.0.1:15667/ >/dev/null
```

The Collector's component-status endpoint is intentionally private to the
container at `127.0.0.1:13133/status`; it is not a host listener. Inspect its
native result together with the container lifecycle and downstream smoke test:

```bash
sudo podman healthcheck run ai-agent-observability-otel-collector
sudo podman inspect --format '{{.State.Health.Status}}' ai-agent-observability-otel-collector
```

The healthcheck requires the traces pipeline to report `healthy: true` and
`StatusOK` or the configured recoverable `StatusRecoverableError` state during
its recovery window. Do not treat a running Collector process, an open OTLP socket, or
an HTTP response from a different service as Collector readiness.

## Browser access

Use an SSH tunnel from a trusted workstation rather than changing the default
bind address:

```bash
ssh -N \
  -L 15667:127.0.0.1:15667 \
  -L 15000:127.0.0.1:15000 \
  -L 14318:127.0.0.1:14318 \
  target-host
```

Then open `http://127.0.0.1:15667` or `http://127.0.0.1:15000` locally. The
first Laminar login uses the passwordless local-email flow. The email set by
`LAMINAR_ADMIN_EMAIL` receives the pending workspace invitation; configure it
before first initialization if a different operator identity is required.

## Backups and upgrades

Before an approved source update, use
`deploy/prepare-reviewed-upgrade.sh --plan` from the clean reviewed candidate
to record its exact Git, Compose, Collector, and Dockerfile identities. The
planner is intentionally non-mutating: it prints the exact arguments for a
root-owned, narrowly allowlisted host wrapper. The current generic
`podman-svc` read-only wrapper is insufficient for materialization, volume
backup, image build, or Compose update and must not be bypassed. Do not grant
generic `podman`, `docker`, `compose`, a shell, or unrestricted environment
execution through sudo.

The required host wrapper must accept only the candidate SHA and three file
hashes emitted by the planner. Its deployment and backup paths are fixed when
the wrapper is installed and it accepts neither caller-provided paths from
argv/environment nor paths printed by the planner. It must create a mode-0700
backup outside the deployment tree, preserve target `.env`, invoke the reviewed
materializer with its approval guard, snapshot this project's named volumes
before an approved update, and support rollback only to that recorded backup.
It must refuse arbitrary paths, project names, Compose files, volume deletion,
and image pruning. Its installation and use are separate root-reserved
mutations.

Back up the eight named volumes with a host-approved, quiesced procedure before
upgrading. At minimum, preserve Laminar PostgreSQL, ClickHouse, Quickwit, and
MLflow PostgreSQL/RustFS data. Record the image tags and Compose commit with
each backup. Never use `down -v` as a backup or rollback mechanism.

For an upgrade, change one pinned version, run the static CI gates, pull/build
only the affected image, and use `docker compose up -d` for this project. Check
health, logs, an OTLP smoke span, and persistence after restart. Roll back by
restoring the prior checked-in tags and the approved data snapshot; do not
delete live volumes to force a migration.

## Failure boundaries

The Collector has one bounded, fsync-backed sending queue per downstream
exporter on `otel-collector-data`; Laminar's RabbitMQ state is also retained on
its own named volume. A Collector acknowledgement still is not proof that both
backends durably stored a trace. Retries can duplicate delivery, and queue or
storage exhaustion can lose pending spans. The Collector's normal metrics expose
queue depth/capacity and failed enqueue/send counters on the existing loopback
metrics endpoint; inspect them before and after a controlled replacement.

The persistent queues preserve accepted requests across Collector process
replacement, not an end-to-end delivery guarantee. Quiesce producers, record a
non-sensitive trace identity, query MLflow and Laminar independently before and
after replacement, and record matching rules and row/span counts. Do not infer
backend storage from HTTP 200, Collector health, a queue file, or a restarted
container. The named volumes preserve product and queue state but are not a
consistent backup snapshot; back up and restore only through an approved,
quiesced procedure.

The Laminar bootstrap applies workspace/project creation, collector-key
replacement, and invitation creation in one PostgreSQL transaction. A failed
statement rolls back the replacement, preserving the previous key. This does
not coordinate a key rotation with a running Collector: recreate the appropriate
services using the approved rotation procedure and verify ingestion afterwards.

### Provision a read-only query account

The checked-in `deploy/laminar/provision-query-readonly.sh` is the reviewed
procedure for the separate operator query path. Before running it, confirm the
deployment directory, Compose project, Laminar PostgreSQL and ClickHouse
container names, and the configured `LAMINAR_PROJECT_ID` against the same live
stack. Run it only as root with the explicit approval guard:

```bash
cd /opt/ai-agent-observability/deploy
sudo env OBSERVABILITY_QUERY_PROVISION_APPROVED=true \
  ./laminar/provision-query-readonly.sh
```

The helper performs a deployed schema preflight, preserving the existing
Collector `is_ingest_only=true` project key row, then creates an operator key
and a ClickHouse user with `readonly = 1`, bounded execution time, memory,
rows, bytes, and threads. It grants `SELECT` only on `default.spans` and
`default.spans_v0`, verifies those grants and both queries, writes the new
operator key to a mode-0600 root-owned file, and updates only the two
read-only ClickHouse values in `.env`. A legacy `CLICKHOUSE_RO_USER=lmnr`
writer alias is admitted through live preflight and migrated to
`lmnr_query_ro_<nonce>`; an already existing target account is refused.
Credentials stay in protected files or stdin; they are not passed as
command-line values.
The helper does not restart the stack.

Before any persistent write, the helper backs up `.env`, the existing operator
key file, and the scoped PostgreSQL operator row. It installs the new key before
the database commit. The PostgreSQL backup reads the restore SQL and the exact
row ID/digest in one repeatable-read transaction while locking the project and
scoped operator row. The replacement preassigns its row UUID and takes the same
project-first lock order, so a changed row fails the compare-and-swap check
without being deleted. If the PostgreSQL client fails after sending the
transaction, the outcome is marked unknown and rollback reconciles the
preassigned candidate by its exact ID and expected fields: an absent candidate
skips exact row compensation while the overall commit outcome remains unknown,
an exact match is restored, and a mismatch retains the row and exits 70 for
manual review. If reconciliation or compensation cannot complete, the
candidate key and owner-only reconciliation evidence remain on disk with the
printed paths.
Rollback then compensates the PostgreSQL row, ClickHouse account, key file, and
`.env` in a fixed order when the outcome is known or has been reconciled. The
helper prints the sanitized container identity and image ID plus root-only
backup paths. Keep those backups until the query consumer has been checked; if
compensation reports an incomplete rollback, stop and reconcile using the
printed paths and the same project/container identities. When ClickHouse
ownership cannot be verified by the staged user UUID and password, the helper
preserves a mode-0600 ownership record and read-only password config and exits
70; it never removes the possibly foreign account. Authorized root operators
must serialize this procedure with other ClickHouse account administration.
The UUID check and name-based DROP are not an atomic ClickHouse primitive.
Record the exact container and image identity with any live evidence, and
classify a failed query or backend check as unverified.

- Image pull/build failure: build evidence is unavailable; existing running
  services are not changed by the failed build.
- Database or search failure: health and end-to-end evidence are unavailable;
  inspect only this project's named containers and volumes.
- Collector export failure: inspect downstream health and Collector logs; the
  queue is bounded and retries are finite.
- Authentication failure: rotate the project key in the deployment `.env` by
  an approved procedure and recreate only this project's bootstrap/Collector
  path. Never place the key in a command-line transcript.
