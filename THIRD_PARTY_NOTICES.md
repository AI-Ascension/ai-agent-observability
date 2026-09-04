# Third-party notices and provenance

This repository assembles upstream container images; it does not relicense
their contents. Review the license and security advisories for every image
before redistribution.

| Input | Pinned input | Provenance |
| --- | --- | --- |
| MLflow | `ghcr.io/mlflow/mlflow:v3.16.0` | [MLflow repository](https://github.com/mlflow/mlflow), Apache-2.0 project license |
| Laminar app/frontend | `ghcr.io/lmnr-ai/*:v0.2.3` | [Laminar repository](https://github.com/lmnr-ai/lmnr), Apache-2.0 project license |
| Laminar ClickHouse XML | release source at `v0.2.3` | Adapted into `deploy/laminar/`; retain this attribution and the upstream license |
| OpenTelemetry Collector | `otel/opentelemetry-collector-contrib:0.160.0` | [Collector releases](https://github.com/open-telemetry/opentelemetry-collector-releases), Apache-2.0 project license |
| ClickHouse | `clickhouse/clickhouse-server:26.5` | [ClickHouse](https://github.com/ClickHouse/ClickHouse) |
| PostgreSQL | `postgres:15` / `postgres:16` | [PostgreSQL](https://www.postgresql.org/about/licence/) |
| RustFS | `rustfs/rustfs:1.0.0-alpha.83` | [RustFS](https://github.com/rustfs/rustfs) |
| RabbitMQ | `rabbitmq:4.3.5-management` | [RabbitMQ](https://github.com/rabbitmq/rabbitmq-server) |
| Quickwit | `quickwit/quickwit:v0.8.2` | [Quickwit](https://github.com/quickwit-oss/quickwit) |
| AWS CLI | `amazon/aws-cli:2.33.25` | [AWS CLI](https://github.com/aws/aws-cli) |

The adapted XML files are derived from Laminar commit
`f0d19c93e32b0e008e38903e7006d5dcc0e96a52` (release `v0.2.3`). No upstream
application source is copied into this repository.
