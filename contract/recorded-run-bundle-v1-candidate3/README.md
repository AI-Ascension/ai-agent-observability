# Recorded-run bundle v1 candidate 3

Status: proposed, not admitted or released. Owner: sts2-protocol. Producer:
sts2-harness. Review consumers: ascension-workflow-studio and ai-agent-observability.
MIT; original schema, profile and synthetic fixtures. No host bytes are included.

The normative structural source is
[the schema](../../schemas/recorded-run-bundle-v1-candidate3.schema.json); this directory
contains its byte-identical copy. This document owns semantic/package rules that
JSON Schema cannot express. The executable conformance oracle is
[validate.mjs](../../tools/recorded-run/validate.mjs), Node 24, no npm dependencies.
The library accepts bytes and returns validated data; the CLI reads one local file.
Nothing in the product Rust crate acquires filesystem, transport or execution authority.

## Interface and pin

Run from the repository root:

```sh
node tools/recorded-run/validate.mjs path/to/recording.zip
node --test tools/recorded-run/*.test.mjs
```

CLI exit 0 emits a JSON summary: valid, semantic_digest, recording_identity,
evidence, completeness, streams, event_records, accounting_records and
unsupported_records. Exit 1 emits only a fixed error code, without source text
or local paths. Importers must complete validation before exposing any records.
The module exports validateBundle(bytes), schemaDigest, semanticDigest(manifest),
privacyDigest(kind, sourceText) and sha256(bytes). validateBundle returns
manifest, omissions, events, accounting and summary.

Pin schema bytes by manifest.contract_schema_sha256. Pin the entire candidate
artifact by its SHA256SUMS digest; verify that inventory and exact schema copy.
tooling.json binds the exact validator/test source files by repository-relative
paths and hashes; it does not create cross-repository implementation dependencies.
Candidate 3 wire format_version is 1.0.0-candidate.3. It is intentionally rejected
by any other version. A release or wire change must get a fresh version/pin;
no published artifact may be silently rewritten. This initial candidate is
under review until the coordinator records producer/two-consumer agreement.

## ZIP subset and resource bounds

One classic single-disk ZIP. STORED (0) and raw DEFLATE (8) only. Version-needed
20; general flags 0 or UTF-8 flag 0x800 only. No encryption, descriptors, ZIP64,
extras, comments, prepended/trailing bytes, duplicate members, directory members,
symlinks, hardlinks, device entries, or overlapping regions. Creator is either
DOS version 20 with external attributes 0, or Unix version 20 with external
attributes 0x81a40000 (regular 0644 file); internal attributes and disk-start are 0.
Local and central name/method/flags/CRC/sizes/time/date must agree. Central entries
are in physical local-entry order, with contiguous locals then contiguous central
entries then the 22-byte EOCD. The manifest's path array is sorted separately.
Exporters should also write physical entries in ASCII path order.

Paths are lowercase ASCII, at most 128 bytes, matching
`^(?:[a-z0-9][a-z0-9_-]{0,31}/)*[a-z0-9][a-z0-9_.-]{0,63}$`.
No repairs or normalization. Equality is byte equality. The only v1 members are
manifest.json, records/events.ndjson, reports/omissions.json and optional
records/accounting.ndjson. Unknown optional profiles do not authorize extra files.
Manifest is the sole unlisted member; no recursive manifest checksum.

Maximum archive 16 MiB, extracted total 32 MiB, entries 32 including manifest,
individual data entry 16 MiB, manifest 256 KiB, omissions 1 MiB, records 25,000
across files, record before LF 64 KiB UTF-8, JSON depth 32 containers,
100,000 values per document. Source row counts also cap at 25,000 per stream.
Limits are ceilings; record and total byte caps both apply. Inflation must limit
actual output to min(advertised size, entry cap, remaining total cap), abort during
expansion, consume exactly the compressed extent, and verify actual size/CRC.
Node's oracle uses maxOutputLength; browser implementations need bounded decoding
in a cancellable worker. No filesystem extraction or remote artifact fetching.

## JCS and digests

Use RFC 8785 JCS (https://www.rfc-editor.org/rfc/rfc8785): UTF-16 key ordering,
ECMAScript finite binary64 numbers, valid Unicode, no normalization, duplicate keys
forbidden. Manifest and omissions use UTF-8 JCS with no BOM or trailing newline.
Each NDJSON record is JCS plus exactly one LF including the last row; no blanks,
CRLF or partial final records. Empty NDJSON is zero bytes. Entry SHA-256 hashes
raw uncompressed bytes including LF. An importer can reject duplicates and
noncanonical numbers by comparing raw input to canonical output before admission.
Before parsing, bound bytes and nesting. Unsafe numeric counters are schema-invalid;
nanoseconds, sequences, generations, token values and large counts are decimal
strings of 1–20 digits, no leading zeros. No conversion through float is permitted.

semantic_digest is SHA-256 of JCS(manifest) with only
integrity.bundle_semantic_digest omitted, retaining the integrity object.
ZIP metadata is not in scope. Arrays are not reordered by JCS: manifest entries,
required/optional profiles and omissions streams must be sorted and unique.

privacyDigest(kind, sourceText) is SHA-256 of UTF-8
`ai-ascension.recorded-run.v1/` + kind + NUL + exact sourceText.
Admitted kinds: bundle-id, run, action, provider-request, seed, state,
observation, unsupported-value. Structured source values use JCS as sourceText,
not implementation formatting. Original source digests retain original digest scope.

bundle_id uses kind=bundle-id and sourceText=JCS(recording.identity). It is stable
across revisions of a logical run and is not the semantic revision digest.
recording.identity is required even for empty streams: the adapter derives it
from the source owner's run identity, or an explicit digest of the recording
directory basename using kind=run (never the host or full private path).
A digest gives integrity, not authenticity or gameplay success.

## Identities, evidence and ordering

The closed common identities map distinguishes run, session, episode, trajectory,
request, action, trace, model_execution, workflow, instance, mcp_session, lease,
operation, correlation and provider_request. Missing keys mean unavailable; do not
invent placeholder identities. Each present value has namespace and value.
Ordinary source identifiers keep exact spelling within the schema's safe token
alphabet. Nonconforming values require an explicit documented privacy transform.
All admitted profile strings exclude ASCII whitespace/control and C1 controls;
this semantic rule also rejects a terminal LF tolerated by some regex end anchors.
Action values are digest-only in ai-ascension.action.sha256, using kind=action.
Provider request values are optional digest-only in ai-ascension.provider-request.sha256,
using kind=provider-request. Neither raw value is admitted.

Train integer trajectory.model_execution_id becomes an exact decimal string in
seed-readiness.trajectory.model-execution. Accounting harness_model_execution_id
keeps its string in seed-readiness.accounting.model-execution. The actual probe
found them unequal; never invent a join, even if later strings happen to match.
Namespaces for source-owned identities are adapter-declared and stable; the
logical recording identity has a separate field and role from runtime/session identities.
Tuple equality alone is not forbidden: an owner can use a single identifier for coincident
lifetimes. Neither equality nor unequal spelling proves a join. Consumers retain the
role and namespace and only derive relationships from an explicit source-owner mapping.

Evidence dimensions are process_exit (unknown/completed/failed), request
(unknown/accepted/rejected), action (unknown/accepted/settled/rejected/cancelled),
outcome (unknown/observed), gameplay (unknown/episode_failed/completed).
episode_failed means the harness episode failed, not authoritative game defeat.
Common gameplay_result represents completion only with explicit authority identity,
source profile/schema digest and witness digest; result distinguishes victory,
defeat and completed. These are producer evidence assertions, not authenticity.
The legacy seed-readiness adapter may not emit gameplay_result: current evidence
supports only unknown or episode_failed. Action/seed settlement is record-scoped;
manifest request/action stay unknown. Manifest process exit derives from its sole
process result; gameplay derives from episode_failed or gameplay_result, never
from provider completion. Conflicting completion/failure claims are rejected.

Order records by (source.stream ASCII, record_ordinal, subrecord_ordinal).
Ordinals are zero-based physical source rows. Subrecords start at zero and are
contiguous per row. Preserve duplicate source rows under distinct ordinals.
stream_sequence, when present, is source evidence; it may have gaps or repeat and
must not be repaired. Default inspection order is source order; an optional time
sort compares decimal unix_ns numerically, puts missing times last, and breaks ties
by the source tuple. Label time sort presentation-only, never causal order.

## Completeness and reconciliation

reports/omissions.json is authoritative for source-row counts. Each stream names
state, input_records, emitted_rows, filtered_rows, unsupported_rows, rejected_rows,
output_records, dispositions and field_omissions. Required streams are trajectory,
decisions, mcp, provider-accounting, result, manifest, even when absent.
Input counts include one rejected final row for a malformed/truncated tail.
Unknown/absent streams use input_records=null with every count zero and no ranges.
A present empty stream has input_records=0. Known input counts obey:

`input_records = emitted_rows + filtered_rows + unsupported_rows + rejected_rows`

Emitted rows are distinct source ordinals in either output file. A diagnostic or
opaque record counts as emitted, not additionally unsupported. output_records is
the number of physical emitted records, so fan-out does not inflate source counts.
dispositions contains sorted, disjoint inclusive first/last ranges for non-emitted
rows, with fixed reason and disposition. Emitted ordinals and ranges must partition
0..input_records-1 exactly, with no omissions or overlaps. Per-field omissions
count affected rows and may overlap across rules; they never participate in the
row equation. Only one entry per rule; each count <= input_records.

Interrupted state requires a final singleton rejected range with partial_final_record.
omitted state requires all rows filtered; unsupported state requires all unsupported.
Completeness complete means a stable source snapshot, reconciled scanned sources,
no rejected/unsupported rows or interrupted/unknown/unsupported streams. It permits
declared absent optional streams and deliberate filtered data; it says nothing
about gameplay or availability of all historical data. partial or unknown remains
truthful when snapshot stability or source coverage is uncertain.

An interrupted source may yield a finalized partial bundle; an interrupted archive
export is never admitted. Harness writes a temporary file and finalizes atomically.
Same recording identity and same semantic digest is an idempotent re-import.
A changed semantic digest is a separate revision; v1 grants no automatic merge or
overwrite semantics. Consumers retain revision history or require explicit replace;
they quarantine conflicting producer/immutable identities or final evidence.

## STS2 seed-readiness profile

ai-ascension.recorded-run.common.v1 is mandatory. The known STS2 payload profile is
ai-ascension.sts2.seed-readiness.v1. Required unknown profiles fail before use.
Optional unknown profiles preserve only an opaque common record with content_digest,
byte count and media type, never arbitrary source payload/text. The envelope stays
known; unknown envelope/profile fields are rejected. Unknown optional content is
visibly unsupported; v1's privacy boundary does not carry its raw bytes.

The concrete JSON Schema closes every known payload; omissions/diagnostics contain
no arbitrary message. Field mapping for seed-readiness-controller-release-v2:

| Source | Projection |
| --- | --- |
| seeded_run_receipt | seed_start; only protocol/schema/context digests, generation, seed digests/match, status, host-ready/run-start/effect flags and named identities |
| model_decision | decision_summary, action digests, exact model-execution namespace, optional observation_summary and reused flag |
| action_receipt status Unknown with effect null | action_outcome status unknown, every evidence dimension unknown; no effect or fabricated settlement |
| operation_wait_completed | diagnostic code operation_wait_completed; all evidence unknown |
| episode_failed | diagnostic code episode_failed, gameplay episode_failed; raw error_code withheld |
| decisions row | decision_summary action digests; rationale and process identity omitted |
| provider accounting | accounting file only, schema/source statuses and counts/usage under closed allowlists |
| result row | process_result exit_code; guest omitted; zero means process completed only |
| MCP rows | no output; filtered raw_mcp_disallowed, source row ranges retained in report |
| source manifest | provenance fields from reviewed allowlist; row filtered private_source_metadata |

Unknown source status/event becomes a diagnostic with kind=unsupported-value digest.
Source spelling Unknown maps only to normalized unknown. No other action status
has an admitted source mapping in candidate 3. Observation summaries carry
generation, state/observation digests, legal-action count, and optional player:
{hp, max_hp, energy, gold}. Each present player counter is a nonnegative decimal
string of at most 20 digits. Missing counters remain absent; no zero defaults.
These counters are admitted public gameplay observations. No raw observation,
action ID, seed, player/card/enemy fields, rationale, private paths, raw MCP,
provider output or arbitrary error text. Seed settlement requires an adapter-validated
seeded-run-v1 receipt, observation and run_started witness; schema checks alone
cannot prove source validity. Broader runtime payload profiles can be added by
their owners through a versioned artifact, without changing current source claims.

Accounting is authoritative only in records/accounting.ndjson; events never duplicate it.
Counts (event/turn/stdout/stderr) are decimal strings, not usage. Usage has unit=tokens,
scope=model_execution and value_status reported/measured/estimated/unknown/not_applicable.
Unknown and not_applicable require null; other states require an explicit decimal value.
Missing token field means not supplied, never zero. Current source reported maps to
reported, not measured. completed execution and valid decision do not imply gameplay.
Optional public provider/model labels require adapter review; lexical schema admission
alone does not make a private string safe. Unprobed status fields are omitted or unknown.

## Candidate 3 review corrections

Candidate 2 remains immutable at ../recorded-run-bundle-v1/; its pinned inventory
is 41d760f8c41064c4e6b49a48dbe6e1a6c8f2a9958afbc50374986a54858fd598.
A runnable original tooling snapshot is in ../../history/recorded-run-candidate2/.
Do not use the new validator to attest candidate 2; candidate 3 is a new wire pin.

For the STS2 payload profile, enforce source-stream mapping: seed_start,
observation_summary and action_outcome come from trajectory; decision_summary
comes from trajectory or decisions; accounting comes from provider-accounting;
process_result comes only from result. A process_result in decisions cannot
supply process completion. Common gameplay_result and optional unknown profiles
retain their own source streams; these STS2 restrictions do not generalize to them.

STS2 diagnostic codes operation_wait_completed, episode_failed and
unsupported_source_event come only from trajectory. unsupported_source_status
comes from trajectory or provider-accounting. invalid_source_record,
partial_final_record and unsupported_profile may describe any of the six known
STS2 streams subject to their reconciliation rules. unsupported_source_event and
unsupported_source_status require value_digest; its source hash domain is
unsupported-value. Source-free diagnostics may omit value_digest. A validator
checks digest representation; only the producer can verify the omitted source value.

Manifest declarations and opaque payloads share the same profile-name grammar:
^[a-zA-Z0-9][a-zA-Z0-9_.:+-]*$, length 1–128. This preserves already-valid
manifest names including uppercase, colon and plus instead of narrowing them.

Disposition pairs are closed: raw_mcp_disallowed => filtered (mcp only),
private_source_metadata => filtered (manifest only), unsupported_source_event =>
unsupported (trajectory), unsupported_source_status => unsupported (trajectory or
provider-accounting), invalid_source_record => rejected (any source), and
partial_final_record => rejected (any source, interrupted state, singleton last row).
optional_stream_absent is not a row disposition: absent streams use null input and
zero counts with no ranges. Per-field redactions remain independent of row counts.

The public byte API accepts Buffer/Uint8Array, checks byteLength before creating a
Buffer view, rejects shared backing buffers, and uses a bounded zero-copy view with
its byteOffset/byteLength. Callers must keep the input stable for the synchronous
validation call. Rejected oversized input triggers no Buffer.from call. The CLI
also retains its pre-read bound. For NDJSON, scan both files' LF-delimited records
with one 25,000-record budget before parsing ANY record JSON. Check each line's
64-KiB cap during that scan, then retain a shared parsing budget as defense in depth.
Thus two individually small streams cannot materialize 25,001 record objects.
