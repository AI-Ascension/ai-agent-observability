# Changelog

All notable changes to this repository are recorded here.

## [Unreleased]

- Scope the operator Laminar query to the `sts2.*` gameplay attribute KEYS via
  `JSONExtractKeys` before ordering/limiting so recorded-run imports cannot fail
  or crowd out gameplay rows (the scope is value-independent), default the
  MLflow experiment id to the deployment `MLFLOW_EXPERIMENT_ID` with
  `--experiment-id` as an explicit override, and validate that id as a bounded
  non-negative integer before any request or evidence.
- Add a bounded, loopback-only operator query consumer
  (`deploy/laminar/operator-query.mjs`) for gameplay acceptance, pin the exact
  Laminar `/v1/sql/query` and MLflow trace-search contract, preserve the
  Collector ingest-only key restriction, document the read-only privilege scope
  and rollback records, and add simulated fail-closed tests plus a separate CI
  job.
- Admit the configured bind address in the MLflow Host allowlist and document
  a systemd drop-in for deployment directories other than the unit default.
- Fail closed on missing deployment listener settings and validate every
  published binding; keep the MLflow backend credential out of process arguments.
- Exercise invalid rendered bindings and secret-safe bootstrap errors in CI.
- Fix the initializer's UUID variant generation, reject malformed persisted
  identities in the Laminar bootstrap, apply the bootstrap's database changes in
  one transaction, admit the published MLflow port in its Host allowlist, and
  exclude `.env` from the `deploy/` build context.
- Add a loopback-first MLflow, Laminar, and OpenTelemetry Collector Compose
  deployment for AI-agent research.
- Add rootful Podman systemd orchestration, first-run secret generation, and
  live-evidence procedures.
