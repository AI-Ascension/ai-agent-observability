# Recorded-run consumer

Status: implemented against proposed `1.0.0-candidate.2`; not an admitted release.
The protocol owner supplies the portable format and the harness supplies sanitized
exports. This consumer does not read Train recording directories, derive producer
semantics from raw logs, fetch artifact URLs, or execute imported content.

## Exact pins and execution

Node 24.16.0 supplies the CLI, bounded decompressor and SQLite. No npm dependencies.
The complete protocol artifact is vendored in `contract/recorded-run-bundle-v1/`.
The independent implementation checks the inventory and all bound files at startup.

| Pin | Value |
| --- | --- |
| Wire version | `1.0.0-candidate.2` |
| Schema SHA-256 | `d5098e5f969d99707d3ad1d97acdbc803285b93f1eb1dcfe5dc3f63c534192af` |
| SHA256SUMS SHA-256 | `41d760f8c41064c4e6b49a48dbe6e1a6c8f2a9958afbc50374986a54858fd598` |
| Synthetic golden ZIP SHA-256 | `a4f7b97df3ee55c35bb42c97ef57518e7a634c700c332025e08db4a3af785c1c` |

From the repository root, supply a validated-format portable ZIP and a private
operator-owned destination directory for the import database:

```sh
node deploy/recorded-run/import.mjs import recording.zip imports.sqlite
node deploy/recorded-run/import.mjs inspect imports.sqlite RUN_KEY
```

`RUN_KEY` is returned by import. The first command completes all archive,
canonical JSON, schema, evidence, profile and reconciliation checks before
creating the DB. Its output contains identity digests, counts, evidence and
candidate version, never the input path. Inspect returns admitted snapshot data.
Input ZIPs are read-only; their private source location is never stored.

Explicit delivery uses the same existing loopback Collector boundary:

```sh
node deploy/recorded-run/import.mjs import recording.zip imports.sqlite \
  --collector http://127.0.0.1:14318/v1/traces
```

Only literal loopback HTTP addresses are accepted; credentials, query strings,
redirects, external hosts and arbitrary artifact fetches are disallowed.
The Collector retains downstream credentials and fans out to MLflow/Laminar as
configured by this repository. The importer never reads deployment credentials.
The default command emits no network traffic. Existing deployments/listeners are
not modified by the CLI. No live-control, recovery or execution-replay path exists.

## Tracking model and retries

The local SQLite `runs` table has one row per exact namespaced recording identity.
`revisions` holds immutable summaries keyed by logical run and semantic digest.
Distinct namespaces never join, including Train's unequal trajectory and accounting
model-execution IDs. Counts, usage statuses, units and decimal values are stored
without floating-point conversion. Unknown/not-applicable usage stays null; absent
usage remains absent. No totals are fabricated across accounting records/revisions.

Same run and same semantic digest: duplicate/no-op, including changed ZIP metadata
or compression. Different semantic digest: append a snapshot revision under the
same run. Changed producer name/source format, changed established run-level
identity, or conflicting known terminal process/gameplay evidence is rejected
without modifying prior data. Missing evidence never erases older evidence.
Snapshots are not automatically ordered by recency or merged. A failed import is
reported with a fixed code; the caller retains its input for separate review.

An import transaction stages an OTLP outbox. Every revision has a deterministic
root span; all revisions of one logical run share a domain-separated OTLP trace ID.
Child spans retain source tuple, source timestamp as a decimal attribute, exact
identities, evidence and known payload summaries. Imported spans use import time
and explicit `recorded.*` attributes; they do not impersonate historical live
`sts2.*` spans or claim measured historical duration. Each span has the semantic
digest so accounting is queried by revision and never summed across snapshots.
Unknown optional payloads remain inert digest envelopes locally; only unsupported
status and common metadata are forwarded. Artifact-reference spans contain only
the admitted relative path, byte length, media type and digest.

Outbox sends are transactionally claimed. HTTP 200 with a valid OTLP JSON success
response marks a part acknowledged; a repeat import does not resend acknowledged
parts. Partial-success, timeout, network errors, or a crash after claiming a part
leave delivery unknown/sending. Further sends fail with
`delivery_reconciliation_required` rather than risk duplicating an ambiguous send.
Endpoint changes for already claimed/sent parts fail. Operator reconciliation must
query the exact trace/span IDs in both backends before any reviewed state repair;
this CLI provides no blind reset/resend switch. Do not delete the database to retry.

Collector acknowledgement is not durable dual-backend evidence. Its existing
queues/retries can lose or redeliver traffic. The importer therefore does not
claim exactly-once remote delivery. Keep the private database with the deployment
and back it up consistently. SQLite writes use transactions, foreign keys and a
busy timeout; a newly created DB is mode 0600. Use an operator-owned parent folder.

## Validation and provenance

```sh
node --test tests/recorded-run-*.test.mjs
```

Tests cover six shared valid ZIPs, 21 invalid ZIPs, canonical JSON ambiguity,
bounds, archive/header safety, precision, privacy sentinels, truthful evidence,
durable duplicates/revisions and uncertain-delivery handling. The synthetic Train
shapes contain two unknown action outcomes and an episode failure, with independent
provider completion. Seed-start settlement is separate from settled gameplay actions.
Candidate 2 optionally admits numeric player hp/max_hp/energy/gold as decimal
strings; arbitrary player/observation text remains forbidden.

The pinned artifact, its README/schema/vectors and this consumer's test fixture
are MIT-licensed protocol-owner material. Synthetic fixtures are not Train source
bytes. The portable protocol includes checksums of its conformance tooling; this
consumer implements its own reader/projection and never runs imported executable
content. Vendor updates must copy a complete newly published byte set, change the
pins, review semantic changes and rerun shared vectors and backend checks.

## Disposable real Collector and MLflow test

The test uses the repository's pinned MLflow 3.16.0 and Collector Contrib 0.160.0,
with the same OTLP receiver, memory/batch processors and MLflow exporter settings.
It starts fresh processes on dynamically allocated loopback ports and a disposable
MLflow SQLite backend. Laminar is omitted from this local test; no production stack
or deployment credentials are used. MLflow anonymous telemetry and optional job
execution are disabled. Job execution otherwise attempts to write read-only
`/dev/shm` on this test VM.

One-time local test prerequisites (not production deployment commands):

```sh
python3 -m venv .local-test/mlflow-env
.local-test/mlflow-env/bin/python -m pip --isolated --disable-pip-version-check install \
  --no-cache-dir --index-url https://pypi.org/simple mlflow==3.16.0
curl -fsSL -o .local-test/otelcol.tar.gz \
  https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.160.0/otelcol-contrib_0.160.0_linux_amd64.tar.gz
```

Verify the release archive before extracting. Its official `.sha256` value is
`7bb60c584c241c86261c2b8697cd3725dd8c56691f5ad5d98454eaa005b47b0c`:

```sh
sha256sum .local-test/otelcol.tar.gz
tar -xzf .local-test/otelcol.tar.gz -C .local-test otelcol-contrib
node tests/recorded-run-runtime.mjs
```

The runner queries real MLflow span data, checks admitted accounting and distinct
identities, repeats import, appends a synthetic revision, restarts MLflow and
requeries the same trace. `finally` stops every process it starts. Logs, generated
configuration, local state and a sanitized `evidence.json` are retained under a
printed `.local-test/runtime-*` directory. That directory is ignored by Git and
build context; repository Python-source checks exclude this disposable upstream
test environment only. The importer has no Python application dependency.

An optional positional argument selects a coordinator-supplied portable failed-run
bundle for the same local runtime probe. It validates the known failed-run evidence
and skips the synthetic revision mutation. The probe compares admitted record
identities, payloads (including accounting status, unit, scope and exact values),
evidence and stream counts with stored MLflow attributes. It checks that duplicate
import leaves the full trace unchanged, that MLflow retains it across restart,
and that the source ZIP hash is unchanged. Generated evidence contains only
digests, counts, evidence enums and verification results; full trace data remains
in the ignored local test directory.

The coordinator's sanitized Train candidate 2 artifact passed this probe with
SHA256 `2575de7ba78baa30d1036233a0fc234a5b0e1e6d8988e10df62c139aaee37f8b`.
The privacy-safe result is [recorded-run-train-local-tracking.json](evidence/recorded-run-train-local-tracking.json):
one persistent trace, 19 spans, eight events and one accounting record. Both action
outcomes remain unknown, gameplay is `episode_failed`, and process exit is
`failed`. Source completeness remains partial/unverified. The supplied artifact
was unchanged; duplicate import and backend restart preserved the complete trace.
This proves local backend interoperability for these sanitized bytes. Independent
review and organization-wide candidate admission remain coordinator-owned.

OTLP acknowledgement semantics follow the [OTLP specification](https://opentelemetry.io/docs/specs/otlp/).
The test inspected installed MLflow 3.16.0 `server/otel_api.py` and
`server/handlers.py` for actual ingestion/search APIs; it uses no provider SDK calls.
