# Operator query gameplay-telemetry acceptance

Status: unverified until a deployment operator records every gate below.

This record is the operator-owned companion to issue #8. The repository-owned
consumer, its provisioning helper and its contract tests run in CI or any
unprivileged checkout; the host, credential, live-record and restart fields
must be captured on the target host after the exact source and pinned images
are selected. Keep credentials, key-file contents, raw span attributes, prompts,
model output, host paths and backup contents private; attach only sanitized
values, bounded identities and immutable IDs.

## Repository snapshot

The source delivery this record accepts against is fixed at the `main` commit
below. Every later change to the consumer, the provisioning helper or the
contract must be re-pinned here before its evidence is attached.

- Repository commit: `6d39c53878fb12fb261c5fa811877724b06466c6`
- Delivering pull requests (merged, `confirmed`):
  - #14 `28a48590afb75b07590e1b78ea47dae08f5c3ade` — separate operator query
    credentials and guarded rotation (`deploy/laminar/provision-query-readonly.sh`)
  - #36 `d89271659c1f0d840fda9b600278fef339c440c4` — bounded operator query
    consumer (`deploy/laminar/operator-query.mjs`)
  - #38 `13a21e28ccbca04e915774b4b740e2217e08a774` — gameplay span scope and
    default MLflow experiment
  - #40 `c13184d31e237c82237e61d6af41d23c457a05a1` — consistent CLI experiment
    validation
  - #42 `851ae38f18be2c81875b5f96f949dc1688fa51bd` — bounded evidence and
    effective MLflow Host contract
- Contract: [`docs/OPERATOR_QUERY.md`](../OPERATOR_QUERY.md)
- Offline contract tests (`tests/operator-query-contract.test.mjs`, 17 tests,
  CI job "Validate bounded operator query contract"; simulated services only):
  1. `dotenv values are parsed as literal data and never executed`
  2. `only loopback listener URLs are admitted`
  3. `the SQL projection is bounded and allowlisted`
  4. `a simulated ingest-only key cannot query while the operator key can`
  5. `the gameplay scope excludes real recorded-run spans before the row limit`
  6. `the old substring scope is proven unsafe against real recorded-run spans`
  7. `the response shape and allowlist fail closed on unknown fields`
  8. `span timestamps are bounded scalars and fail closed on drift`
  9. `MLflow is queried through its effective, admitted loopback authority`
  10. `the real fetch transport sends the URL authority as the Host header`
  11. `the operator token is read from a protected file, never argv`
  12. `the operator path is loopback-only, approved, and secret-free in evidence`
  13. `the MLflow experiment defaults to MLFLOW_EXPERIMENT_ID unless overridden`
  14. `a deployment without MLFLOW_EXPERIMENT_ID fails closed unless overridden`
  15. `a non-numeric or oversized MLFLOW_EXPERIMENT_ID fails closed and never reaches a request`
  16. `an invalid CLI --experiment-id fails with the documented code`
  17. `an invalid CLI experiment id fails before any transport call`
- Shell invariants: `tests/operator-query-invariants.sh`,
  `tests/query-provision-invariants.sh` (CI job "Validate deployment contract").

Operator-recorded fields (blank until captured on the target host):

- Deployed repository commit and branch:
- Compose project:
- Target host alias:
- Observation time (UTC):
- Laminar image ID/digest and upstream revision:
- MLflow and ClickHouse image IDs/digests:
- ClickHouse `default.spans` schema check (attributes column type):
- Operator key file path mode and owner (never its contents):
- ClickHouse read-only account name (never its password):

## Running the consumer

From the deployment directory on the target host, after the credentials have
been provisioned, run exactly the command documented in
[`docs/OPERATOR_QUERY.md`](../OPERATOR_QUERY.md) "Running the consumer":

```bash
cd <deployment-dir>/deploy
sudo env OBSERVABILITY_OPERATOR_QUERY_APPROVED=true \
  node laminar/operator-query.mjs \
  --env-file "$PWD/.env" \
  --key-file /root/ai-agent-observability/laminar-query-key \
  --limit 100
```

Paste its bounded sanitized output here once before and once after the scoped
restart. The command reads the deployment `.env` as data, requires a loopback
`BIND_ADDRESS`, refuses a key file with any group or other permission bit, and
prints only the allowlisted correlation and outcome fields. It opens no
listener, starts or restarts no container, rotates no credential and deletes
no durable data. A successful response, a health response, an empty HTTP `200`
result, or a synthetic span is not acceptance evidence for any row below.

## Gate record

| Gate | Evidence required | Status | Owner / next action |
| --- | --- | --- | --- |
| Credential provisioning | Approved target-host access; operator Laminar key provisioned by `provision-query-readonly.sh` into a root-owned mode-`0600` file outside the repository; key never printed, committed or passed as an argument | unverified | Deployment operator |
| Deployed image/schema identity | Exact Laminar, MLflow and ClickHouse image IDs/digests, the deployed upstream Laminar revision, and the `default.spans.attributes` column type matching the pinned `v0.2.3` schema | unverified | Deployment operator |
| Read-only privilege scope | Actual ClickHouse grants for the operator account limited to `SELECT` on `default.spans` and `default.spans_v0`; `readonly = 1` and the documented resource limits; no `WITH GRANT OPTION`, no `ON *.*`, no write path | unverified | Deployment operator |
| API/Host contract | Deployed `/v1/sql/query` returning HTTP `404` for the ingest-only key and `{"data": [...]}` for the operator key; MLflow `/api/3.0/mlflow/traces/search` accepting the published loopback `Host` authority | unverified | Deployment operator |
| Nonempty gameplay identities in Laminar | Real harness gameplay spans with `sts2.*` attributes returned by the consumer before restart; recorded non-sensitive `trace_id`/`span_id` and `sts2.run_id`/`sts2.episode_id` identities | unverified | Deployment operator |
| Nonempty identities in MLflow | Real harness traces in the deployment experiment returned by the consumer before restart; recorded `trace_id`/`state` identities correlating with the Laminar rows | unverified | Deployment operator |
| Scoped restart | Producers quiesced; only the initially running project containers restarted; initially stopped one-shot containers preserved; unrelated services and Compose projects untouched | unverified | Deployment operator |
| Durable-identity comparison | Both queries repeated after the restart returning the same non-sensitive identities recorded before it | unverified | Deployment operator |
| Rollback record | Root-only backups under `/run/ai-agent-observability/` (`env_backup`, `key_backup`, `key_backup_state`, `db_backup_sql` with row ID/digest) retained for every configuration change; reconciliation evidence for any uncertain write | unverified | Deployment operator |
| Independent review | Review of the exact source diff at the pinned commit and of the deployment procedure, the privacy regression checks, and the before/after query evidence by a reviewer who did not perform the deployment | unverified | Deployment operator |

## External gate (verbatim from issue #8)

> Deployment operator supplies approved target access and protected credential
> path; validates exact deployed image/schema, read-only privileges and
> API/Host behavior.

> Record nonempty expected real-harness gameplay identities in both Laminar and
> MLflow.

> Perform the authorized scoped restart and compare durable identities,
> preserving stopped one-shot containers and rollback records.

> Acceptance requires an independent review of the exact source diff and
> deployment procedure, privacy regression checks, real harness telemetry
> reaching both products, and before/after restart query evidence. Health
> responses, empty HTTP 200 results, or synthetic spans alone are insufficient.

The 17 contract tests and the shell invariants are `source-derived` or
`confirmed` component evidence only; they exercise simulated services and
prove nothing about the deployed host. Issue #8 remains open while any row
above is not `confirmed`; the repository-owned scope (separate credential and
rotation, bounded loopback-only consumer, fail-closed contract tests) has
merged, but the deployment operator must still attach sanitized evidence for
every row above before any production acceptance is claimed. A repository
merge or a green CI run does not close this issue.
