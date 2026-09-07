# Workstream 4 observability ledger

Last updated: 2026-09-07 (America/New_York)

## OBS-005 — runtime-v3 telemetry contract correction

- Date: 2026-09-07 (UTC)
- Status: `source-derived`; live O1/O2 acceptance remains pending root reservation and an independent integrated verifier
- Owner: `/root/obs_recovery` for the harness source handoff; this repository owns the deployment contract and query helper
- Canonical event vocabulary: `sts2.run_started`, `sts2.model_decision`, `sts2.action_dispatch`, `sts2.settlement_observation`, `sts2.recovery`, `sts2.failure`, `sts2.terminal_observed`, `sts2.run_finished`, and post-flush `sts2.export_status`
- Canonical identity attributes: `sts2.operation_id` and `sts2.action_id` contain domain-separated digests and every runtime span carries `sts2.id_encoding=digest`; OTLP `traceId` remains separate from `sts2.trace_id`
- Wire profile: `otlp-http-json-v1`, bounded OTLP/HTTP JSON to `127.0.0.1:14318/v1/traces` with `Content-Type: application/json`; response validation requires one JSON content type, complete length-delimited framing, zero rejected spans, and an empty `partialSuccess.errorMessage`
- Lifecycle: one bounded FIFO preserves enqueue sequence, the run-finished span follows all accepted child events, and the exporter status span is sent after the flush drain; a replay prefix or nonterminal error emits no `sts2.run_finished`
- Privacy: exporter and process output retain only bounded categories, generations, provider execution identities, and digests; prompts, rationale, raw provider output, full observations, credentials, and paths are excluded
- Query helper correction: one locked PostgreSQL snapshot emits the operator restore SQL and ID/digest together; replacement preassigns its row ID, compares the exact snapshot under a project-first lock, and rollback reconciles an unknown client outcome by that candidate ID and expected fields before compensating only an exact unchanged row and restoring the backup
- Evidence: harness source handoff at `coordination/telemetry-gameplay-integration-handoff-20260907.md`; exact integrated component result at `coordination/verifier-results/integrated-harness-l3-result-20260907.md`; fresh live query and restart evidence are unverified

OBS-005 supersedes the older OBS-002 proposal's protobuf and raw-ID wording while
preserving its requirement for distinct identity namespaces and independent
verification.

## OBS-001 — source and live deployment audit

- Parent: workstream 4 / root
- Owner: `/root/observability`
- Status: `active`; read-only audit complete, end-to-end gameplay evidence pending
- Repository: `AI-Ascension/ai-agent-observability`
- Branch/worktree: `obs/workstream4-20260906` at `b25880376d3a3334c77f58637267db93581c4c77`; `sts2-project-worktrees/live-v3-llm-20260905/observability`
- Owned paths: this repository's deployment, documentation, tests, and ledger
- Dependencies: root-controlled observability runtime reservation; gameplay/harness exporter ownership; rootful host access for project credentials and container inventory
- Acceptance: O1 and O2 require real gameplay OTLP ingestion, useful success/failure action and settlement spans, correlated MLflow/Laminar queries, controlled restart retention, and privacy/redaction evidence.
- Source evidence: `deploy/otel-collector.yaml` receives OTLP/HTTP+gRPC and fans out through `otlp_http/mlflow` and `otlp_http/laminar`; `docs/ARCHITECTURE.md`, `docs/OPERATIONS.md`, `docs/PRIVACY.md`, and `docs/EVIDENCE.md` define the boundary and evidence vocabulary.
- Live read-only evidence (2026-09-06 16:33 EDT): Train host `completetrain-B550-GAMING-X-V2`; root filesystem `100%` with about `4.7G` free; system service `ai-agent-observability.service` active/exited, `Result=success`, `ExecMainStatus=0`; loopback `15000/health=200`, `18000/health=200`, frontend `15667` redirects, collector `14318/v1/traces` accepts POST (`405` to GET). Existing deployment source hashes identify commit `42d23816177da7a3d8bd6f7295d306f81baaf867`; current source head is `b258803...` and its Compose file differs, so live identity is stale until a reserved redeploy.
- Prior live evidence (historical, not current workstream proof): memory records a synthetic OTLP span retained in both products after restart. It does not satisfy real gameplay telemetry.
- Verifier: pending independent verifier at exact final head.
- Findings/blockers: no root runtime reservation yet; rootful `.env` is mode 0600 and unreadable by the SSH account; no gameplay exporter exists in current harness worktrees; do not claim O1/O2 complete from the historical synthetic span.

## OBS-002 — gameplay exporter contract request

- Parent: workstream 4 / root
- Owner: `/root/observability` (contract proposal); root/gameplay owns any shared harness edits
- Status: `pending dependency`
- Repository/path proposal: dedicated harness files under the root-assigned harness worktree, e.g. `crates/harness/src/telemetry.rs` plus `crates/harness/src/bin/runtime_support/runtime_v3_telemetry.rs`; no edits made from this worktree.
- Required identity fields: `run_id`, `episode_id`, `trajectory_id`, `trace_id`, `instance_id`, `session_id`, `operation_id`, `action_id`, `generation`, and model execution identity where applicable. Keep namespaces distinct and correlate with common OTLP trace/span IDs without replacing harness identities.
- Required spans/events: canonical runtime-v3 `sts2.run_started`/`sts2.run_finished`, `sts2.model_decision` with an action digest and model execution identity, `sts2.action_dispatch`, `sts2.settlement_observation` only after a fresh successor/effect witness, and bounded `sts2.failure`/`sts2.recovery` records.
- Export contract: versioned OTLP/HTTP JSON to the Collector endpoint from `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://127.0.0.1:14318`); one bounded FIFO queue; explicit flush/shutdown before process exit; export failures recorded in post-flush telemetry status and never used to mutate gameplay outcomes.
- Privacy contract: allowlist attributes, hash or omit host/profile/path/provider identifiers, omit prompts, model outputs, credentials, cookies, saves, proprietary text, and full observations; tests inject sentinel secret/private markers and assert they never enter serialized spans/logs.
- Required root action: assign a shared harness path and integrate the exporter around the final runtime-v3 episode recorder. Return exact commit and runtime artifact identity before live testing.
- Verifier: independent harness verifier required; observability verifier will query both backends after the author handoff.

## OBS-003 — live success/failure and persistence acceptance

- Parent: workstream 4 / root
- Owner: `/root/observability`
- Status: `blocked on OBS-002 and root reservation`
- Acceptance evidence plan: run one real model-controlled success or terminal defeat and one real failure/recovery path with the final harness artifact; record only sanitized run/trace identifiers; query MLflow's trace API and Laminar's documented SQL/query API for matching identity/status/action/settlement rows; quiesce producers, restart only this stack under root reservation, and re-query both records; capture deployed source/image IDs and loopback listener scope.
- Required privacy evidence: source-level allowlist review, serialized exporter tests with secret/private markers, and live query payload audit confirming no credential, prompt, raw model output, proprietary host data, or personal path is retained.
- Verifier: independent agent must inspect exact exporter diff and evidence, then rerun static and live queries.
- Findings/blockers: historical synthetic evidence is insufficient; controlled restart and telemetry POST are runtime mutations and require root reservation.

## OBS-004 — bounded Collector encoding smoke

- Date: 2026-09-06 (America/New_York)
- Status: `component evidence only`; O1/O2 remain pending
- Input: one root and one child OTLP/HTTP JSON request to loopback
  `127.0.0.1:14318/v1/traces`, using only synthetic identifiers prefixed with
  `sts2-encoding-smoke-20260906`, finite enum attributes, and digest-shaped
  values. Request body was 2,550 bytes.
- Result: `HTTP/1.1 200 OK`, parsed response `{"partialSuccess":{}}`, with no
  rejected spans. This proves the reviewed JSON envelope and 32/16-hex ID
  encoding reached the Collector through the root-owned forward. It does not
  prove gameplay, backend persistence, query correlation, or restart survival.
- Source checks: the query provisioning helper passes `bash -n`, the protected
  credential/schema invariant script, and `git diff --check`; the Rust shared
  harness check remains blocked by unrelated in-progress execution-store
  compile errors in that worktree. In an isolated copy with that unrelated
  module omitted, all five telemetry unit tests passed, including the opt-in
  source-rendered Collector smoke against the same forward.
