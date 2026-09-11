# Ascension Observability

Self-hosted AI-agent observability and experiment tracking for AI-Ascension.

This is an operations companion to [Ascension](https://github.com/AI-Ascension/sts2-harness),
the AI Ascension flagship toolkit. **The Climb — by AI Ascension** may link to
approved run context, while this repository keeps its private telemetry and
deployment boundaries intact.

This repository provides an isolated Docker Compose deployment that runs on
Docker or rootful Podman:

- MLflow for experiment, run, parameter, metric, and artifact tracking.
- Laminar for trace-native agent execution, evaluation, and debugging views.
- OpenTelemetry Collector as the single OTLP/HTTP and OTLP/gRPC ingestion
  boundary, exporting the same trace to both systems.
- PostgreSQL, RustFS, ClickHouse, RabbitMQ, and Quickwit as the stateful
  services required by those platforms.

The repository name is intentionally product-oriented rather than vendor-
or host-oriented. It leaves room for additional AI-agent research consumers
without putting deployment files in the Rust-only STS2 harness repository.

## Start

From the `deploy` directory on the target host:

```bash
./init.sh
```

`init.sh` creates a mode-0600 `.env` with fresh local secrets, validates the
Compose model, and starts the stack. It does not overwrite an existing `.env`.
The default listeners bind to `127.0.0.1`; use the operations guide before
changing that boundary.

Useful local endpoints after startup:

| Service | Default endpoint | Purpose |
| --- | --- | --- |
| MLflow | `http://127.0.0.1:15000` | Runs, experiments, and artifacts |
| Laminar UI | `http://127.0.0.1:15667` | Trace and evaluation UI |
| Laminar HTTP | `http://127.0.0.1:18000` | Direct OTLP/HTTP and API access |
| Laminar gRPC | `127.0.0.1:18001` | Direct OTLP/gRPC access |
| OTLP Collector HTTP | `http://127.0.0.1:14318` | Recommended agent endpoint |
| OTLP Collector gRPC | `127.0.0.1:14317` | Recommended agent endpoint |
| OTEL Collector metrics | `http://127.0.0.1:18888/metrics` | Owner-side quiescence observer |

The operator should use an SSH tunnel or an approved private reverse proxy for
browser access. The initial deployment intentionally does not modify shared
Caddy routes.

## Recorded-run import (candidate)

The independent recorded-run consumer validates portable ZIP recordings, stores
immutable local snapshot revisions, and can deliver admitted tracking metadata
through the existing Collector. It supports `1.0.0-candidate.3`; release admission
and real Train interoperability remain separate gates.

```sh
node deploy/recorded-run/import.mjs import recording.zip imports.sqlite
```

Requires Node 24.16.0. Default import is offline. See
[`docs/RECORDED_RUN.md`](docs/RECORDED_RUN.md) for Collector delivery, duplicate
and update behavior, exact contract pins, and the disposable MLflow runtime test.

## Repository map

- [`deploy/compose.yaml`](deploy/compose.yaml) — complete service topology.
- [`deploy/Dockerfile.mlflow`](deploy/Dockerfile.mlflow) — pinned MLflow
  runtime wrapper.
- [`deploy/Dockerfile.laminar`](deploy/Dockerfile.laminar) — Laminar app,
  frontend, and bootstrap image targets.
- [`deploy/init.sh`](deploy/init.sh) — non-destructive first-run setup.
- [`deploy/otel-collector.yaml`](deploy/otel-collector.yaml) — OTLP fan-out.
- [`docs/OTEL_HEALTH_PROBE.md`](docs/OTEL_HEALTH_PROBE.md) — Collector readiness
  contract and native probe boundary.
- [`systemd/ai-agent-observability.service`](systemd/ai-agent-observability.service)
  — boot-time service definition for rootful Podman.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — ownership and data flow.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — deploy, inspect, back up, and
  upgrade procedures.
- [`docs/PRIVACY.md`](docs/PRIVACY.md) — retention, redaction, and egress
  boundaries.
- [`docs/MAP_ARTIFACTS.md`](docs/MAP_ARTIFACTS.md) — bounded optional map
  artifact telemetry contract; source-derived only until both backends are
  queried.
- [`prompts/AI_AGENT_OBSERVABILITY_ORCHESTRATION_PROMPT.md`](prompts/AI_AGENT_OBSERVABILITY_ORCHESTRATION_PROMPT.md)
  — the reusable orchestration prompt requested for multi-agent completion.

## Evidence status

Repository checks are source/build evidence. A successful Compose parse or
image build does not prove a running deployment, trace ingestion, persistence,
or a public route. Live checks are recorded separately by the operator using
the evidence vocabulary in [`AGENTS.md`](AGENTS.md) and
[`docs/EVIDENCE.md`](docs/EVIDENCE.md).

## License and provenance

The orchestration files are MIT-licensed. Container images remain governed by
their upstream licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
before redistributing an assembled image set.
