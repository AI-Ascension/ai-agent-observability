# Changelog

All notable changes to this repository are recorded here.

## [Unreleased]

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
