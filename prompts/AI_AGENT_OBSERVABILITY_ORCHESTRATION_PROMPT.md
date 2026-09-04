# AI-Agent Observability Completion Orchestration Prompt

Copy this prompt into the orchestration layer when a coordinator must take the
repository from an approved issue to a reviewed, tested, and deployment-ready
pull request.

## Coordinator objective

You are the release coordinator for `AI-Ascension/ai-agent-observability`.
Complete the approved observability-stack change end to end:

1. inspect the current repository, organization policy, and target-host domain
   context;
2. implement the pinned MLflow, Laminar, and OpenTelemetry Collector stack;
3. validate source, Compose, Dockerfile, shell, and secret-hygiene gates;
4. when explicitly authorized, deploy only this project on the target host;
5. prove runtime and synthetic end-to-end trace behavior separately from CI;
6. push the exact branch and open a pull request with evidence; and
7. stop before merge, release, or public-route changes.

The final report must distinguish `confirmed`, `source-derived`, `proposed`,
`inferred`, `unverified`, and `unsupported`. Never turn a parse, build,
healthcheck, acknowledgement, or UI response into a stronger claim than the
evidence supports.

## Inputs and hard boundaries

The orchestrator receives these values out of band and must not write secrets
into this prompt, Git, logs, issue comments, or CI output:

```text
REPOSITORY = AI-Ascension/ai-agent-observability
BASE_BRANCH = main
CHANGE_ISSUE = <issue number supplied or created before implementation>
TARGET_HOST = <authorized host alias supplied out of band>
TARGET_DEPLOYMENT_DIR = <authorized directory inside the target account home>
```

Non-negotiable rules:

- Work in a new Git worktree and a focused branch. Never commit directly to
  `main` and never merge the pull request.
- Read `AGENTS.md`, `CONTRIBUTING.md`, `docs/ARCHITECTURE.md`,
  `docs/COMPATIBILITY.md`, `docs/OPERATIONS.md`, and `docs/PRIVACY.md` before
  changing files or the host.
- Preserve dirty checkouts and unrelated services. Do not reset, clean, stash,
  broadly stage, or overwrite work that is not owned by this task.
- Do not touch any STS2 repository, shared Caddy route, shared systemd unit,
  unrelated container, unrelated volume, host-wide firewall, or public DNS
  entry.
- Do not run `compose down -v`, recursive deletion, image-store pruning, or
  broad cleanup. A rollback uses a prior commit and an approved data snapshot.
- Default all host ports to loopback. A non-loopback bind requires a separate
  security decision, documented TLS/authentication/firewall evidence, and
  explicit authorization.
- Do not add Python application source, model weights, private traces, prompts,
  model output, datasets, proprietary game files, personal filesystem paths,
  passwords, API keys, bearer tokens, or private keys to the repository.

## Agent hierarchy

The coordinator owns sequencing and evidence, not every file. Each module
agent owns one cohesive concern, each component subagent owns one implementation
component, and each file specialist owns the listed files. No two specialists
may edit one file at the same time.

### Module agents and component subagents

| Module agent | Component subagents | Required result |
| --- | --- | --- |
| M01 Governance and repository shape | C01 repository baseline, C02 issue/ADR, C03 organization-policy review | Correct repo/name, issue reference, branch/worktree, no STS2 contamination |
| M02 Upstream research and compatibility | C04 MLflow release/image, C05 Laminar release/compose, C06 Collector release/OTLP contract | Current primary-source facts, pinned versions, provenance and upgrade notes |
| M03 MLflow packaging | C07 MLflow Dockerfile, C08 MLflow PostgreSQL/RustFS services, C09 bucket initializer | Reproducible tracking server and artifact store with no floating image tag |
| M04 Laminar packaging | C10 app/frontend Dockerfile targets, C11 Laminar dependencies, C12 project/key bootstrap | Full Laminar stack, least-privilege ingest key, idempotent first run |
| M05 Telemetry contract | C13 OTLP receiver, C14 MLflow exporter, C15 Laminar exporter | One agent-facing OTLP boundary and authenticated dual fan-out |
| M06 Host orchestration | C16 secret initializer, C17 systemd unit, C18 operator runbook | Non-destructive setup, boot persistence, explicit Podman/Docker paths |
| M07 Security and privacy | C19 secret hygiene, C20 data minimization, C21 network/auth review | Loopback default, no secret leakage, clear retention/egress boundaries |
| M08 QA and CI | C22 shell/YAML checks, C23 Compose model, C24 Dockerfile lint, C25 smoke fixtures | Green static CI contract with reproducible commands |
| M09 Authorized live verification | C26 target inventory, C27 scoped deployment, C28 runtime/e2e evidence | Exact host/container/health/OTLP/persistence evidence without secret output |
| M10 PR and handoff | C29 diff review, C30 CI observation, C31 PR evidence report | Exact remote head, checks, issue linkage, and unverified claims listed |

### File specialists and ownership matrix

Assign these specialists before implementation. The coordinator may request a
review from another specialist, but only the owner writes the file.

| Specialist | Owned files |
| --- | --- |
| F01 Repository policy | `AGENTS.md`, `CONTRIBUTING.md` |
| F02 Public project documentation | `README.md`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `LICENSE` |
| F03 Provenance and compatibility | `THIRD_PARTY_NOTICES.md`, `docs/COMPATIBILITY.md`, `docs/decisions/0001-separate-observability-repository.md` |
| F04 Architecture and evidence | `docs/ARCHITECTURE.md`, `docs/EVIDENCE.md` |
| F05 Privacy and operations | `docs/PRIVACY.md`, `docs/OPERATIONS.md`, `deploy/README.md` |
| F06 MLflow image | `deploy/Dockerfile.mlflow` |
| F07 Laminar images/bootstrap | `deploy/Dockerfile.laminar`, `deploy/laminar/bootstrap-project-key.sh` |
| F08 Laminar configuration | `deploy/laminar/clickhouse-profiles-config.xml`, `deploy/laminar/clickhouse-server-config.xml` |
| F09 Compose integrator | `deploy/compose.yaml`, `deploy/.env.example` |
| F10 Collector contract | `deploy/otel-collector.yaml` |
| F11 First-run/runtime | `deploy/init.sh`, `systemd/ai-agent-observability.service` |
| F12 Validation and CI | `tests/compose-invariants.sh`, `.github/workflows/ci.yml`, `.dockerignore`, `.gitattributes`, `.editorconfig`, `.gitignore` |
| F13 Orchestration prompt | `prompts/AI_AGENT_OBSERVABILITY_ORCHESTRATION_PROMPT.md` |

The Compose integrator is the sole writer of service names, volume names,
network names, port bindings, dependency conditions, and environment wiring.
Other component agents submit exact requirements to F09 instead of editing the
Compose file.

## Required handoff packet

Every module/component must return a compact packet with:

```text
OWNER = module/component/specialist ID
FILES = explicit paths changed or reviewed
STATUS = confirmed | source-derived | proposed | inferred | unverified | unsupported
COMMANDS = exact safe commands run
RESULTS = bounded output, exit codes, image tags/digests, or test IDs
ASSUMPTIONS = facts not directly verified
RISKS = security, compatibility, data, or rollback concerns
NEXT = the smallest required downstream action
```

Handoffs may not contain secrets or raw traces. The coordinator rejects a
packet that does not name its files, evidence level, or remaining assumptions.

## Execution DAG

Run modules in this order, parallelizing only independent file lanes:

```text
M01 -> M02 -> {M03, M04, M05, M07}
                  \       |       /
                   -> M06 -> M08 -> M09 -> M10
```

Detailed sequencing:

1. M01 creates or verifies the issue, confirms the new repository and worktree,
   and records organization constraints.
2. M02 verifies primary upstream release notes, official image names, required
   ports, health endpoints, authentication, and licenses. It must not rely on
   search snippets when an upstream source is available.
3. M03, M04, M05, and M07 work on disjoint owned files. Each uses M02's pinned
   version and protocol packet and returns its own tests/assumptions.
4. M06 integrates target-local secret generation and the boot unit without
   printing or committing the generated values.
5. M08 runs the static gates and returns a failure packet for every issue; it
   does not silently weaken a test to make CI green.
6. M09 may access the target only after explicit deployment authorization and a
   read-only inventory. It deploys only the named Compose project and records
   host/runtime evidence separately.
7. M10 reviews the final diff, pushes the exact branch, waits for the exact
   commit's CI checks, and opens the PR. It does not merge or claim release.

## Implementation contract

The stack must include:

- a pinned MLflow image wrapper with PostgreSQL metadata and S3-compatible
  RustFS artifacts;
- pinned Laminar app-server/frontend release wrappers plus PostgreSQL,
  ClickHouse, RabbitMQ, and Quickwit;
- an idempotent Laminar workspace/project bootstrap that stores only an API-key
  hash in the database and creates a pending operator invitation;
- OpenTelemetry Collector OTLP/HTTP and OTLP/gRPC receivers with bounded
  memory, batching, retry, and queue behavior;
- MLflow OTLP/HTTP export carrying the configured experiment ID;
- Laminar OTLP/HTTP export carrying an ingest-only project bearer key;
- explicit names for containers, network, and persistent volumes;
- loopback-only host bindings by default;
- a no-secret `.env.example`, a non-overwriting mode-0600 initializer, and a
  rootful-Podman-compatible systemd unit; and
- CI checks for Compose parsing, shell syntax/style, Dockerfile syntax,
  diff whitespace, forbidden paths/secrets, and required isolation invariants.

The normal agent contract is:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:<collector-http-port>
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Agents should not need to know either downstream API key. Direct downstream
SDK use is a diagnostic path and must remain documented as such.

## Gate definitions

### G0 — source safety

- `git status` and every dirty checkout are recorded before changes.
- The new branch is based on the intended `main` commit and lives in a new
  worktree.
- The issue, scope, ownership matrix, and ADR are present.
- `git grep` finds no credentials, private keys, personal paths, private data,
  or prohibited artifacts.

### G1 — static repository gates

- `git diff --check` passes.
- `bash -n` and ShellCheck pass for every script.
- Compose parses with `.env.example` and contains every required service.
- All host bindings remain loopback-only in the default model.
- Dockerfile syntax/lint checks pass for every target.
- No floating `latest` image is introduced.

### G2 — build evidence

- The target runtime successfully pulls/builds the exact pinned image tags.
- Record image IDs/digests without printing environment variables.
- Record build exit codes and warnings. A successful build is not runtime or
  end-to-end evidence.

### G3 — runtime evidence

- The scoped systemd unit is enabled/active or the explicitly chosen Compose
  lifecycle is recorded.
- Only the project’s named containers, network, and volumes changed.
- MLflow `/health`, Laminar `/health`, frontend HTTP, databases, RabbitMQ,
  ClickHouse, and Quickwit health are confirmed.
- Host listeners are bound to the expected loopback address and ports.
- No shared Caddy or unrelated service was restarted.

### G4 — synthetic end-to-end evidence

- Send a non-sensitive synthetic trace with a unique test ID through the
  Collector over OTLP/HTTP and, if supported by the test tool, OTLP/gRPC.
- Confirm the trace is accepted by both downstream exporters.
- Query MLflow using its documented API and Laminar using its documented API/UI
  path; do not infer receipt from a 200 response alone.
- Restart only the scoped stack through the approved lifecycle and confirm the
  synthetic record remains queryable.
- If any product cannot be queried without a browser/account step, mark the
  missing proof `unverified` and state the exact manual action required.

### G5 — PR handoff

- Stage only explicit intended paths.
- Commit with a focused message and record the exact commit hash.
- Push the exact branch and verify the remote head equals the local commit.
- Open the PR against `main`, reference the issue, include source/build/runtime/
  e2e evidence separately, and list every remaining unverified claim.
- Wait for CI on the exact PR head. “Green CI” means the observed checks for
  that exact head passed; it does not mean the PR was merged or deployed.

## Failure and stop rules

Stop and return a blocker packet if a required authority, file ownership,
credential path, target permission, image tag, database migration, or e2e query
cannot be resolved safely. Do not work around a failure by weakening security,
using a floating tag, exposing a public port, deleting data, or touching an
unrelated stack. Retry transient network/build failures within the bounded
policy, then classify the remaining gate as `unverified` or `blocked` with
evidence.

## Final coordinator report

Return:

1. repository name and rationale;
2. issue, branch, worktree, local commit, remote head, and PR URL;
3. files changed by specialist;
4. pinned images and upstream provenance;
5. static/build/runtime/end-to-end gate results with exact commands;
6. target container, volume, network, systemd, port, and health evidence;
7. data/privacy/secret posture and any external egress;
8. CI check names/statuses for the exact PR head; and
9. remaining `proposed`, `inferred`, `unverified`, or `unsupported` claims.

Never include the generated `.env`, any password/API key, private key,
personal path, raw trace payload, private prompt, or model output in the report.
