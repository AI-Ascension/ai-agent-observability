# Compatibility and version policy

## Pinned inputs

The following tags are explicit inputs in `deploy/compose.yaml` and the two
Dockerfiles. They are source-derived from the upstream release/configuration
surfaces used for this implementation; a tag is not a digest and should be
revalidated before an upgrade or redistribution.

| Component | Version/tag | Role |
| --- | --- | --- |
| MLflow | `v3.16.0` | Tracking server image |
| MLflow Python integrations | `boto3==1.43.88`, `psycopg2-binary==2.9.12` | RustFS and PostgreSQL support |
| Laminar | `v0.2.3` | App-server and frontend release images |
| OpenTelemetry Collector Contrib | `0.160.0` | OTLP receiver and HTTP exporters |
| ClickHouse | `26.5` | Laminar analytics store |
| PostgreSQL | `15` / `16` | MLflow / Laminar metadata stores |
| RustFS | `1.0.0-alpha.83` | S3-compatible MLflow artifact store |
| RabbitMQ | `4.3.5-management` | Laminar queue transport |
| Quickwit | `v0.8.2` | Laminar search/index store |
| AWS CLI | `2.33.25` | Idempotent RustFS bucket initializer |
| Alpine | `3.22.1` | One-shot Collector queue-volume ownership initializer |

Backup/restore separately requires an operator-approved, preloaded GNU tar image
referenced by its immutable SHA-256 image digest. No such backup image has been
validated or activated by these source changes; BusyBox tar is insufficient for
the documented ACL/xattr-preserving procedure.

## Supported runtime boundary

- Docker Engine with Docker Compose v2, or rootful Podman exposed through its
  Docker-compatible API socket.
- Linux hosts with an amd64-compatible container runtime are the intended target
  for the initial deployment (`proposed`; deployment evidence remains separate
  from the static CI checks). Other architectures depend on the upstream
  images publishing a compatible manifest and are `unverified` until tested.
- Host ports must be free or explicitly overridden in `.env`.
- A persistent filesystem is required for all eight named volumes, including
  the Collector queue volume and RabbitMQ data volume.

## Upgrade rules

Upgrade one product family at a time. Read the upstream release notes, update
the table and `THIRD_PARTY_NOTICES.md`, run Compose/Dockerfile checks, then run
the live health and OTLP smoke gates. Do not use floating `latest` tags in a
pull request. A successful pull is not proof that a changed schema is
backward-compatible with an existing volume.

## Protocol notes

- The recommended input contract is OTLP/HTTP or OTLP/gRPC into the Collector.
- MLflow's OTLP trace ingestion is HTTP-based in this topology; the Collector
  converts the incoming gRPC stream when necessary.
- Laminar accepts OTLP/HTTP and OTLP/gRPC and requires a project API key for
  trace ingestion. The bootstrap service provides an ingest-only key for the
  local deployment.
