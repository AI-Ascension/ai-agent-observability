# Architecture

## Intent

This repository is the deployment boundary for AI-agent research telemetry. It
keeps the researcher-facing tracking plane independent from the STS2 harness:
the harness or another agent emits OpenTelemetry; this stack receives and
stores the resulting records. No container in this repository is authoritative
for game state, legal actions, experiment policy, or model behavior.

## Data flow

```text
AI agent / harness / evaluator
        |
        | OTLP/HTTP or OTLP/gRPC
        v
OpenTelemetry Collector :14318 / :14317
        |\
        | \\ OTLP/HTTP + x-mlflow-experiment-id
        |  \
        |   v
        |  MLflow :5000 ---- PostgreSQL + RustFS
        |
        | OTLP/HTTP + Laminar project bearer key
        v
Laminar app-server :8000/:8001/:8002 ---- PostgreSQL + ClickHouse + RabbitMQ + Quickwit
        ^
        |
Laminar frontend :5667
```

The host-facing bindings are loopback-only by default. Internal service names
are used for container-to-container traffic, so changing a host port does not
change the internal protocol contract.

## Ownership

| Boundary | Owner | Stored or served data |
| --- | --- | --- |
| Agent/harness | Calling repository | Run/episode identity and agent-produced spans |
| Collector | This repository | Bounded buffering and authenticated fan-out |
| MLflow | Upstream MLflow | Experiments, runs, metrics, parameters, artifacts |
| Laminar | Upstream Laminar | Traces, spans, evaluation/debugging records |
| MLflow PostgreSQL | MLflow deployment | Tracking metadata |
| RustFS | MLflow deployment | S3-compatible MLflow artifacts |
| Laminar PostgreSQL | Laminar deployment | Users, projects, API-key hashes, metadata |
| ClickHouse | Laminar deployment | Trace and event analytics |
| RabbitMQ | Laminar deployment | Ingest worker queues |
| Quickwit | Laminar deployment | Trace search indexes |

## Startup ordering

1. MLflow PostgreSQL and RustFS become healthy.
2. The bucket initializer creates the configured MLflow artifact bucket.
3. MLflow starts with its PostgreSQL backend and RustFS artifact destination.
4. Laminar PostgreSQL, RabbitMQ, ClickHouse, and Quickwit become healthy.
5. Laminar app-server and frontend start; the frontend applies its migrations.
6. The bootstrap service creates a fixed local workspace/project, a 64-character
   ingest-only project key hash, and a pending invitation for the configured
   local operator email. It exits successfully and does not persist the
   plaintext key in PostgreSQL.
7. The Collector starts and fans out accepted traces to both backends.

The one-shot initializers are idempotent for the generated deployment identity.
Do not reuse a `.env` with a new database volume unless the operator intends to
create a new logical deployment.

## Integration contract

Agents should normally target the Collector:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

The Collector uses OTLP/HTTP for both downstreams. MLflow receives the
`x-mlflow-experiment-id` header and Laminar receives the bearer project key.
Direct SDK access to Laminar or MLflow is supported for diagnostics, but it
should not bypass the shared Collector for normal comparative research traces.

The Collector does not redact arbitrary inputs or outputs. Agents must avoid
sending secrets and personal data, or apply an approved redaction policy before
export. See [`PRIVACY.md`](PRIVACY.md).
