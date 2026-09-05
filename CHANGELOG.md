# Changelog

All notable changes to this repository are recorded here.

## [Unreleased]

- Add a loopback-first MLflow, Laminar, and OpenTelemetry Collector Compose
  deployment for AI-agent research.
- Add rootful Podman systemd orchestration, first-run secret generation, and
  live-evidence procedures.
- Fix the initializer's UUID variant generation, reject malformed persisted
  identities in the Laminar bootstrap, apply the bootstrap's database changes in
  one transaction, admit the published MLflow port in its Host allowlist, and
  exclude `.env` from the `deploy/` build context.
