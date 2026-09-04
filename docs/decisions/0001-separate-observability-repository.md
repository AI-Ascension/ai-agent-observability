# Decision 0001: separate observability deployment repository

## Status

Accepted for the initial deployment.

## Context

AI-Ascension needs researcher logging for agents, but the existing STS2
repositories have explicit product ownership and a Rust-only source policy.
The tracking products are external services with their own databases, image
release cadence, authentication, and operational lifecycle.

## Decision

Create `AI-Ascension/ai-agent-observability` as a separate public repository.
Keep the deployment declarative and integrate the STS2 harness through
OpenTelemetry/HTTP or other documented runtime interfaces. Do not add MLflow,
Laminar, Python packaging, Docker Compose, or host deployment files to
`sts2-harness`.

The initial stack uses an OpenTelemetry Collector fan-out so agents can emit
one trace contract while MLflow and Laminar remain independently replaceable
consumers. Host exposure remains loopback-only until a separate route/security
decision is reviewed.

## Consequences

Positive:

- independent product and image upgrades;
- clear ownership of secrets, volumes, and systemd lifecycle;
- no compile-time dependency from the harness to vendor implementations;
- one agent-facing OTLP endpoint for comparative research.

Costs and limits:

- the deployment has several stateful dependencies;
- trace schemas and retention require operator governance;
- direct UI access needs an SSH tunnel or an approved private proxy;
- the first-run local-email authentication is suitable only for the private
  loopback deployment and must be replaced or constrained before exposure.
