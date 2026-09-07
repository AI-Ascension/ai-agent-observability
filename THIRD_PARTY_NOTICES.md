# Third-party notices and provenance

This repository assembles upstream container images; it does not relicense
their contents. Review the license and security advisories for every image
before redistribution.

| Input | Pinned input | Provenance |
| --- | --- | --- |
| MLflow | `ghcr.io/mlflow/mlflow:v3.16.0` | [MLflow repository](https://github.com/mlflow/mlflow), Apache-2.0 project license |
| Laminar app/frontend | `ghcr.io/lmnr-ai/app-server:v0.2.3`, `ghcr.io/lmnr-ai/frontend:v0.2.3` | [Laminar repository](https://github.com/lmnr-ai/lmnr), Apache-2.0 project license |
| Laminar ClickHouse XML | release source at `v0.2.3` | Adapted into `deploy/laminar/`; retain this attribution and the upstream license |
| OpenTelemetry Collector | `otel/opentelemetry-collector-contrib:0.160.0` | [Collector releases](https://github.com/open-telemetry/opentelemetry-collector-releases), Apache-2.0 project license |
| ClickHouse | `clickhouse/clickhouse-server:26.5` | [ClickHouse](https://github.com/ClickHouse/ClickHouse), Apache-2.0 project license |
| PostgreSQL | `postgres:15` / `postgres:16` (also the base of the `bootstrap` build stage) | [PostgreSQL](https://www.postgresql.org/about/licence/), PostgreSQL License |
| RustFS | `rustfs/rustfs:1.0.0-alpha.83` | [RustFS](https://github.com/rustfs/rustfs), Apache-2.0 project license |
| RabbitMQ | `rabbitmq:4.3.5-management` | [RabbitMQ](https://github.com/rabbitmq/rabbitmq-server), MPL-2.0 project license (some OCF files Apache-2.0) |
| Quickwit | `quickwit/quickwit:v0.8.2` | [Quickwit](https://github.com/quickwit-oss/quickwit), AGPL-3.0 project license; review before redistributing an assembled image set |
| AWS CLI | `amazon/aws-cli:2.33.25` | [AWS CLI](https://github.com/aws/aws-cli), Apache-2.0 project license |
| Alpine | `docker.io/library/alpine:3.22.1` | [Alpine Linux](https://www.alpinelinux.org/), MIT license; used only for the Collector volume ownership initializer |
| MLflow image additions | `boto3==1.43.88`, `psycopg2-binary==2.9.12` (pip, `deploy/Dockerfile.mlflow`) | [boto3](https://github.com/boto/boto3), Apache-2.0; [psycopg2](https://github.com/psycopg/psycopg2), LGPL-3.0 with linking exception |
| Wrapper image packages | `curl` (Debian and Alpine), `openssl`, `ca-certificates` (`deploy/Dockerfile.laminar`) | Distribution packages of the upstream base images; governed by their distribution licenses |

License names in this table were read from each project's `LICENSE` file at the
pinned release on 2026-09-04 (`source-derived`; ClickHouse at the `v26.5.1.882-stable`
tag behind the floating `26.5` image tag) and must be revalidated before
redistribution or any pin change.

The adapted XML files are derived from Laminar commit
`f0d19c93e32b0e008e38903e7006d5dcc0e96a52` (release `v0.2.3`). No upstream
application source is copied into this repository.
