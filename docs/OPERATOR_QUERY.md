# Operator query access

Status: `source-derived` contract plus repository-owned, offline-tested consumer.
Live provisioning, real gameplay telemetry, and before/after restart query
evidence remain external operator gates. This document records the exact
contract the checked-in consumer validates; it is not a live acceptance record.

## Why a separate credential

The Collector authenticates to Laminar with a project key whose database row has
`is_ingest_only = true`. The upstream `/v1/sql/query` route is wrapped by the
standard project validator, not the ingestion validator, so an ingest-only key
receives a blank HTTP `404` there. That restriction is intentional and is
preserved. Operator inspection therefore uses a second, separately provisioned
key with `is_ingest_only = false`; the two credentials are never derived from
each other and the ingestion key is never sent to the query route.

`provision-query-readonly.sh` creates the operator key and writes it to a
root-owned, mode-`0600` file outside the repository (default
`/root/ai-agent-observability/laminar-query-key`). No credential is committed,
printed, or passed as a command-line value.

## Exact deployed API contract

`deploy/laminar/operator-query.mjs` targets only the loopback listeners that
`deploy/compose.yaml` already publishes. It refuses any non-loopback
`BIND_ADDRESS`, listener hostname, userinfo component, or URL path.

### Laminar span query

| Property | Value |
| --- | --- |
| Method and path | `POST /v1/sql/query` |
| Authorization | `Authorization: Bearer <operator key>` |
| Request body | `{"query": "<bounded SELECT>", "parameters": {}}` |
| Success body | `{"data": [ <row object>, ... ]}` |
| Ingest-only key | blank HTTP `404` (upstream project validator) |
| Missing/invalid key | HTTP `401` |
| Unconfigured read-only client | HTTP `500` |

The only projection issued is
`SELECT trace_id, span_id, name, status, start_time, end_time, attributes FROM
default.spans WHERE arrayExists(k -> startsWith(k, 'sts2.'), JSONExtractKeys(attributes)) ORDER BY
start_time DESC LIMIT <n>` with `1 <= n <= 500`. The query is scoped to the
versioned `sts2.*` gameplay namespace before ordering/limiting, so a co-located
recorded-run import (`recorded.*`) cannot crowd out or fail the projection; the
fail-closed attribute validation still applies to the selected gameplay records.

Pinned schema: upstream Laminar `v0.2.3` defines `default.spans.attributes` as a
JSON `String` (`frontend/lib/clickhouse/migrations/1_squashed.sql`), so the scope
extracts the top-level JSON keys and tests the `sts2.` namespace. Because the
scope is key-based, attribute VALUES containing `sts2...` text (as recorded-run
imports may carry) cannot match; a substring test such as
`position(toString(attributes), 'sts2.')` would match those values and admit
recorded-run spans.

The response must have exactly one top-level `data` array; any other top-level
key, a non-array `data`, or a non-object row fails closed. Every row field
outside the projection, and every span attribute outside the STS2 allowlist,
fails closed rather than being silently dropped.

### MLflow trace query

| Property | Value |
| --- | --- |
| Method and path | `POST /api/3.0/mlflow/traces/search` |
| `Host` header | the effective URL authority: the published loopback `<host>:<port>` from the base URL, for example `127.0.0.1:15000` |
| Request body | `{"locations":[{"mlflow_experiment":{"experiment_id":"<id>"}}],"max_results":<n>}` |
| Success body | `{"traces": [ ... ]}` with at most `n` entries |

MLflow validates the full `Host` header, including the published port. The
health probe bypasses that validation, so a healthy container does not prove
the UI/API Host allowlist. Node's `fetch` always sends the URL authority as the
`Host` header and ignores an explicit `host` request header, so the consumer
connects through the published loopback authority (`<BIND_ADDRESS>:<MLFLOW_PORT>`)
that the deployment already admits, and validates that effective authority
before issuing the request; an optional caller-supplied host value may only
confirm it and is refused if it differs. The deployment's MLflow allowlist also
admits the internal `localhost:5000`, `127.0.0.1:5000`, and `mlflow:5000`
authorities, but the consumer only ever dials a loopback base URL, so `mlflow`
service names are not reachable through this path. The experiment id defaults to the
deployment `.env` value `MLFLOW_EXPERIMENT_ID`; the CLI `--experiment-id` flag
is an explicit override used only when passed. Both sources must be a bounded
non-negative integer (at most 19 digits); any other value fails closed with
`mlflow_experiment_id_invalid` before a request is issued or evidence is
produced, so an arbitrary dotenv value can never be transmitted or echoed.

## Bounded allowlisted fields

The only fields retained in evidence are the correlation and outcome fields
defined by [`STS2_TELEMETRY_CONTRACT.md`](STS2_TELEMETRY_CONTRACT.md):

- span: `trace_id`, `span_id`, `name`, `status`, `start_time`, `end_time`;
- gameplay attributes: `sts2.run_id`, `sts2.episode_id`, `sts2.trajectory_id`,
  `sts2.trace_id`, `sts2.instance_id`, `sts2.session_id`, `sts2.operation_id`,
  `sts2.action_id`, `sts2.generation`, `sts2.model_execution_id`, `sts2.status`,
  `sts2.error_code`, `sts2.effect_kind`, `sts2.recovery`, `sts2.id_encoding`,
  `sts2.export_status`;
- MLflow trace: `trace_id`, `state`.

Span `start_time` and `end_time` must be a finite number, a bounded string, or
`null`; any other value fails closed. Never retain credentials, prompts, model
output, raw rationale, host text, private paths, valued saves, or full
observations.

## Minimum ClickHouse read-only privilege scope

The provisioning helper creates a distinct ClickHouse account and grants only:

```sql
GRANT SELECT ON default.spans TO <account>;
GRANT SELECT ON default.spans_v0 TO <account>;
```

Its effective scope is verified after creation: `DEFAULT ROLE NONE`,
`readonly = 1`, `max_execution_time = 30`, `max_memory_usage = 268435456`
(256 MiB), `max_result_rows = 10000`, `max_result_bytes = 16777216` (16 MiB),
and `max_threads = 2`. It has no grant with `WITH GRANT OPTION`, no `ON *.*`
access, and no write path. The Laminar app-server receives the same account
through the `CLICKHOUSE_RO_USER` / `CLICKHOUSE_RO_PASSWORD` Compose values.

The operator Laminar project key and the ClickHouse read-only account are
separate credentials for separate surfaces: the project key authorizes the
`/v1/sql/query` route, and the ClickHouse account is the least-privilege backend
identity that route executes with.

## Running the consumer

```bash
cd <deployment-dir>/deploy
sudo env OBSERVABILITY_OPERATOR_QUERY_APPROVED=true \
  node laminar/operator-query.mjs \
  --env-file "$PWD/.env" \
  --key-file /root/ai-agent-observability/laminar-query-key \
  --limit 100
```

The command reads the deployment `.env` as data (never `source`s it), requires
`BIND_ADDRESS` to be loopback, refuses an operator key file with any group or
other permission bit, and prints bounded sanitized evidence. It opens no new
listener, starts no service, restarts no container, rotates no credential, and
deletes no durable data. A successful response is not by itself proof of
durable storage; acceptance still requires the same non-sensitive identity to
appear in both products before and after a controlled restart.

## Rollback records

Any configuration change is reversible from root-only backups recorded by
`provision-query-readonly.sh` under `/run/ai-agent-observability/`:

- the pre-change `.env` (`env_backup`), the prior operator key
  (`key_backup` plus `key_backup_state`), and the scoped PostgreSQL operator row
  (`db_backup_sql` plus exact row ID/digest);
- for an uncertain or failed ClickHouse or PostgreSQL write, the helper retains
  mode-`0600` reconciliation evidence and prints the exact paths, then exits
  non-zero instead of guessing.

The query consumer itself writes no state, so it requires no rollback beyond
discarding its stdout. Do not delete backups, rotate credentials, recreate
containers, or restore volumes to "fix" a failed query; classify the query
`unverified` and reconcile from the printed identities.

## Remaining external gates

The repository-owned consumer and its simulated tests are not live acceptance
evidence. Closing issue #8 still requires an operator to provision the
credentials on the target host, confirm non-empty real gameplay records in both
products, quiesce producers, restart only the initially running project
containers, preserve stopped one-shot containers, and repeat both queries with
matching durable identities. Record each gate in
[`docs/evidence/operator-query-acceptance.md`](evidence/operator-query-acceptance.md).
