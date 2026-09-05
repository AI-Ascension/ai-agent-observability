# Changelog

All notable changes to this repository are recorded here.

## [Unreleased]

- Fail closed when a listener bind address or host port variable is unset,
  pass the MLflow backend store URI only through the environment, bound the
  Laminar bootstrap readiness waits, tighten the loopback and secret-hygiene
  tests, pin the CI checkout action, and move the systemd unit to a neutral
  deployment path with a documented drop-in.
- Add a loopback-first MLflow, Laminar, and OpenTelemetry Collector Compose
  deployment for AI-agent research.
- Add rootful Podman systemd orchestration, first-run secret generation, and
  live-evidence procedures.
