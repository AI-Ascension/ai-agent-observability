# Map artifacts and operational traces

Status: proposed integration contract with component validation in the companion map visualizer; live Collector/backend delivery requires separate evidence. This change adds no listener, service, credential, retention override or deployment.

## Accepted ingestion boundary

The map visualizer exports optional bounded OTLP/HTTP JSON traces to the existing loopback Collector at `/v1/traces`. JSON requests use `Content-Type: application/json`, hexadecimal trace/span identities and string-encoded 64-bit integer fields, following the [OTLP JSON encoding specification](https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding). The Collector remains responsible for fan-out to MLflow and Laminar. Browser clients never receive Collector credentials or call a backend directly.

The adapter is disabled unless the operator supplies a Collector port. It accepts only loopback, queues at most 64 events, bounds encoded events to 8 KiB, uses one joined worker and finite network deadlines, drops overload explicitly, and permits at most a 500-ms optional flush. Collector failure cannot prevent valid structured graph delivery or local rendering. An HTTP acknowledgement is not evidence that either backend stored the span.

## Fixed trace fields

| Attribute | Meaning | Bound/classification |
| --- | --- | --- |
| `map.stage` | capture, validation, analysis, render, provider delivery, action validation or cache | fixed low-cardinality enum |
| `map.duration_micros` | observed stage duration | integer, at most 600 seconds |
| `map.nodes`, `map.edges` | represented topology sizes | at most 1,024 / 8,192 at presentation boundary; upstream capability can be stricter |
| `map.graph_bytes`, `map.image_bytes` | validated serialized graph and PNG sizes | at most 2 MiB / 16 MiB |
| `map.cache_hit` | local artifact cache result | boolean; not provider prompt-cache evidence |
| `map.stale`, `map.incomplete` | independently observed graph conditions | booleans |
| `map.image_capable` | admitted provider image capability | boolean; not image comprehension |
| `map.invalid_action` | a proposed action failed current binding validation | boolean; never an effect witness |
| `sts2.trajectory_digest` | optional approved decision linkage within one exporter lifetime | keyed digest of a bounded opaque token, or the literal `redacted` marker |

No node/run identifiers become metric labels. No map text, images, base64, prompts, model output, rationale, game/provider credentials, save data or private paths are exported as span attributes. Required run/episode/model-execution and artifact lineage remains in separately validated bundle manifests. Only approved sanitized artifacts may be uploaded to the MLflow artifact store under existing experiment classification and retention policy; this adapter does not automatically upload files.

Trajectory linkage uses domain-separated HMAC-SHA-256 with a fresh operating-system-generated 256-bit key for each exporter instance. Neither the key nor raw token is exported. Repeated tokens link only during that exporter lifetime; restarts and separate exporters are intentionally unlinkable. Descriptive legacy identifiers are redacted. A token's printable representation does not prove entropy, so the keyed digest protects against dictionary lookup even when an admitted token has a predictable value. Cross-process correlation requires a separately reviewed secret-management design and is not enabled by this adapter.

## Bundle inspection

The harness owns `visible-map.json`, `analysis.json`, `decision.json` and their source-time lineage. The visualizer validates matching inputs and supplies deterministic `overview.svg`, `overview.png`, and a read-only viewer presentation file. `manifest.json` binds independent schema/analysis/render versions and exact content digests. Bundles publish atomically and historical action bindings never restore authorization.

Keep the artifact root private and scoped to the experiment. A local map view has no direct game access and works offline. To inspect a historical decision, validate the complete recorded bundle and replay that frame; never enrich it with later discoveries. Retention and deletion remain operator-owned and must preserve applicable research/privacy decisions.

## Validation and rollback

Component tests must capture the actual HTTP body and reject invalid lineage, oversized events and unreachable Collector behavior. Native trace acceptance requires the exact adapter commit, Collector deployment pin, sampled sanitized span ID, and successful retrieval from both backends using separately authorized query access. Missing query credentials remain an explicit gate; do not infer backend storage from port reachability or HTTP success.

Rollback disables the optional exporter and returns to local artifacts. Existing Collector configuration, six backend volumes, credentials and research artifacts remain under their current owners. No service restart is needed for this documentation integration.
