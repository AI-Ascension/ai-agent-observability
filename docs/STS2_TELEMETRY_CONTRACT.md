# STS2 gameplay telemetry contract

This document defines the handoff from the STS2 harness to the observability
deployment. The harness remains responsible for gameplay, provider execution,
run records, and terminal evidence. This repository owns only the Collector
boundary and the MLflow/Laminar deployment. A conforming exporter sends OTLP
to the Collector and does not bypass it.

## Endpoint and delivery behavior

The current runtime-v3 adapter sends bounded OTLP/HTTP JSON to the loopback
Collector at `http://127.0.0.1:14318/v1/traces`. The deployment keeps this
boundary loopback-only; it must not be replaced with a direct MLflow or Laminar
endpoint. The Collector fans out accepted spans to MLflow and Laminar with its
own credentials; gameplay code must never receive or handle either backend's
credentials.

The versioned runtime wire profile is `otlp-http-json-v1`: requests use the
OTLP/HTTP JSON envelope and `Content-Type: application/json` (optional media
type parameters are accepted on responses). Generic Collector support for
OTLP/gRPC and OTLP/HTTP protobuf remains a deployment capability for other
producers and does not change this runtime-v3 input contract.

The exporter owns a bounded queue and a bounded shutdown flush. Export failure
is observable in a local status/result record, but must not retry a gameplay
mutation or change a host settlement result. The process must flush completed
spans before reporting the episode terminal status. A Collector HTTP 200 alone
is an ingestion acknowledgement, not proof that either backend durably stored
the record; acceptance requires a query in both products.

## Identity and span model

Harness identities and OpenTelemetry IDs are separate namespaces. Every
gameplay root span carries the following allowlisted attributes when available:

| Attribute | Meaning | Privacy rule |
| --- | --- | --- |
| `sts2.run_id` | harness run identity | bounded identifier only |
| `sts2.episode_id` | one episode within a run | bounded identifier only |
| `sts2.trajectory_id` | trajectory lineage | bounded identifier only |
| `sts2.trace_id` | harness trace identity | bounded identifier only; do not replace OTLP trace ID |
| `sts2.instance_id` | allocated game instance | bounded identifier only |
| `sts2.session_id` | gateway session identity | bounded identifier only |
| `sts2.operation_id` | idempotent action operation | domain-separated digest; `sts2.id_encoding=digest` |
| `sts2.action_id` | host catalog action identity | domain-separated digest; `sts2.id_encoding=digest` |
| `sts2.generation` | host observation generation | unsigned integer |
| `sts2.model_execution_id` | provider decision identity | bounded integer identity |
| `sts2.status` | accepted/settled/rejected/unknown/terminal outcome | enum only |
| `sts2.error_code` | bounded failure class | enum/code only |
| `sts2.effect_kind` | settlement witness class | enum only |
| `sts2.recovery` | recovery/reconciliation kind | enum only |
| `sts2.id_encoding` | encoding used for identity attributes | `digest` only for this runtime |
| `sts2.export_status` | post-flush export result | `delivered`, `partial`, or `timeout` |

The exporter emits these typed spans/events:

1. `sts2.run_started` is the OTLP root span. `sts2.run_finished` records the
   terminal outcome (`success`, `failure`, or `unavailable`) only after the
   harness has completed cleanup and the exporter has flushed child spans.
2. `sts2.model_decision` records the digest of the selected host action and
   model execution identity. It may record only a finite decision category such
   as `action`, `plan`, or `reobserve`; it must not record a prompt, model
   output, chain of thought, or raw rationale.
3. `sts2.action_dispatch` records the host catalog generation, operation
   identity, action ID, and boundary status. `accepted` is not a settlement.
4. `sts2.settlement_observation` is emitted only after a fresh successor
   observation or same-state effect witness confirms the mutation. It records
   the effect class, resulting generation, and source.
5. `sts2.failure`, `sts2.model_failure`, `sts2.recovery`, and
   `sts2.observation` record bounded transport, stale-catalog, timeout,
   rejection, unknown-effect, cleanup, recovery, and observation classes. They
   must not include raw HTTP bodies, host text, file paths, or provider
   responses.
6. `sts2.export_status` is emitted by the worker after the FIFO has drained and
   reports the result of exporting the preceding spans. It is not queued onto
   the gameplay admission path and never changes a gameplay outcome.

The parent/child relationship must make it possible to find every action and
settlement by the same OTLP trace ID and by `sts2.run_id`/`sts2.episode_id`.
MLflow and Laminar queries in the acceptance record must show the same
non-sensitive correlation values and at least one action plus one settled or
failed outcome for each real run.

## Redaction and tests

The exporter uses an allowlist serializer. It drops unknown attributes and
rejects values above the agreed byte bounds before queueing. Tests must inject
sentinels such as `PRIVATE_PROMPT_SENTINEL`, `MODEL_OUTPUT_SENTINEL`,
`BEARER_TOKEN_SENTINEL`, `C:\\Users\\private\\save`, and a proprietary host
text marker into source event fixtures and assert that none appear in the
serialized OTLP request, exporter logs, or terminal evidence. Tests also cover
empty/oversized IDs, unknown status values, duplicate operation identities,
unknown settlement, transport interruption, and shutdown flush failure.

The deployment Collector intentionally does not redact arbitrary attributes.
The exporter is therefore the privacy boundary for gameplay records. Live
query evidence must retain only bounded IDs, statuses, action/effect codes,
generations, and source/image identities. Never record credentials, private
prompts, raw provider output, proprietary game files, valued saves, personal
paths, or full observations.

## Acceptance handoff

The harness owner must return the exact exporter commit, runtime binary hash,
configuration endpoint, and a sanitized pair of real run IDs (one successful
or terminal defeat and one failed/recovered run). The observability verifier
then queries MLflow's trace API and Laminar's documented query API, captures
matching identity/status/action/settlement rows, quiesces producers, requests a
root-reserved stack restart, and repeats both queries. A green Rust test,
Collector 200, health endpoint, or synthetic trace cannot close O1/O2 by
itself.
