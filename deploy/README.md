# Deployment directory

This directory is self-contained after checkout. Run `./init.sh` once on a
host with Docker Compose or Podman. The script generates `.env` and starts the
full stack; `.env` is ignored by Git and must remain mode `0600`.

The bootstrap rejects malformed project/workspace UUIDs without changing them.
Earlier initializers could generate a five-character UUID variant group starting
with `10` or `11`. For a deployment affected by that defect, preserve the `.env`
and inspect its database identity before correcting only the affected ID: replace
that group's `10` prefix with `a`, or `11` with `b`. Do not regenerate the entire
environment, rotate secrets, or change an already valid database identity.
This repair requires an operator; rerunning initialization preserves the file.

## Runtime choices

- `COMPOSE_ENGINE=docker` uses Docker Compose. On a rootful Podman host, set
  `DOCKER_HOST=unix:///run/podman/podman.sock` and run the initializer with the
  required privilege.
- `COMPOSE_ENGINE=podman` uses the account's Podman Compose provider and
  rootless storage.
- `BIND_ADDRESS` defaults to `127.0.0.1`. Do not change it without reviewing
  authentication, firewall, TLS, and trace-data exposure.

The initializer creates the dedicated `ai-agent-observability-net` network. On
Podman-backed Docker sockets it sets `isolate=false`, which is required for
service-name DNS and container-to-container traffic on hosts that enable
network isolation by default.

## Agent endpoint

Prefer the collector for normal agent traces:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318
OTEL_EXPORTER_OTLP_PROTOCOL=http/json
```

The STS2 runtime uses the versioned `otlp-http-json-v1` profile: bounded
OTLP/HTTP JSON requests to `/v1/traces` with `Content-Type: application/json`.
The Collector can accept protobuf and gRPC from other producers, which does
not alter the STS2 runtime input contract.

The collector handles downstream authentication. If a direct Laminar SDK
connection is needed, use the local `.env` value for `LAMINAR_PROJECT_API_KEY`
through the operator's approved secret-reading method; never paste it into a
shell history, issue, log, or repository.

## Safe lifecycle commands

```bash
docker compose -p ai-agent-observability -f compose.yaml ps
docker compose -p ai-agent-observability -f compose.yaml logs --tail=100 otel-collector
docker compose -p ai-agent-observability -f compose.yaml up -d
```

Do not use `down -v` or prune commands. Use [`../docs/OPERATIONS.md`](../docs/OPERATIONS.md)
for backups, upgrades, systemd, and evidence capture.

## Read-only query access

The Laminar operator query path has separate credentials from the Collector's
ingest-only key and ClickHouse writer account. After reviewing the target
host's deployment identity, provision them with the root-only helper:

```bash
cd /opt/ai-agent-observability/deploy
sudo env OBSERVABILITY_QUERY_PROVISION_APPROVED=true \
  ./laminar/provision-query-readonly.sh
```

The helper reads the root-owned mode-0600 `.env` as data, sends PostgreSQL
credentials through a protected `PGPASSFILE`, and sends ClickHouse credentials
through temporary root-private XML config files. It validates the deployed
`default.spans` table and `default.spans_v0` view, creates the bounded
read-only ClickHouse account, verifies both objects with that account, and
stores the new Laminar operator key at
`/root/ai-agent-observability/laminar-query-key` with mode `0600`. It does not
restart or recreate any service. Inspect the protected `.env` diff and use the
reviewed Compose command for the query consumer afterwards.

The helper retains root-only backups of the pre-change `.env`, local operator
key, and scoped PostgreSQL operator row under `/run/ai-agent-observability/`.
The PostgreSQL backup is one repeatable-read, locked transaction that emits both
the SQL restore statement and the exact row ID/digest from the same snapshot.
The replacement preassigns its row UUID and compares the locked snapshot before
deleting it.
If a PostgreSQL client error leaves the commit outcome unknown, compensation
reconciles that UUID and the complete expected row: an absent candidate leaves
the overall outcome unknown and skips exact row compensation, an exact match is
restored, and a mismatch stops with manual review instead of deleting a changed
row. If reconciliation or compensation cannot complete, the candidate key and
owner-only reconciliation evidence are retained. It checks the live ClickHouse
account before migrating a legacy writer alias, refuses a target-account
collision, and runs deterministic compensation for a failure after the key,
PostgreSQL, or ClickHouse write. Preserve the printed backup paths until the
query path has been verified. If compensation reports an incomplete rollback,
stop and reconcile the exact project and container identities from those
backups. The Collector ingest-only row is checked before the transaction and
is preserved.
