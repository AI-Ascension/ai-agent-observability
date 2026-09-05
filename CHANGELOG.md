# Changelog

All notable changes to this repository are recorded here.

## [Unreleased]

- Fail closed on missing deployment listener settings and validate every
  published binding; keep the MLflow backend credential out of process arguments.
- Exercise invalid rendered bindings and secret-safe bootstrap errors in CI.
- Add a loopback-first MLflow, Laminar, and OpenTelemetry Collector Compose
  deployment for AI-agent research.
- Add rootful Podman systemd orchestration, first-run secret generation, and
  live-evidence procedures.
