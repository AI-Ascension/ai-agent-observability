# Map artifacts and operational traces

Status: `proposed` integration contract for the companion map visualizer. It
adds no listener, credential, retention override, deployment, or runtime claim.
Native Collector and backend delivery require separate evidence.

## Accepted ingestion boundary

An optional map visualizer adapter may emit bounded OTLP/HTTP JSON to the
existing loopback Collector at `/v1/traces`, with `Content-Type:
application/json`. The Collector remains the sole fan-out boundary to MLflow
and Laminar. Browser clients must neither receive Collector credentials nor
call either backend directly.

The adapter is disabled unless an operator supplies a loopback Collector port.
It queues at most 64 events, bounds encoded events to 8 KiB, uses finite
network deadlines, reports overload as a drop, and may flush for at most
500 ms. An HTTP acknowledgement is not evidence that either backend stored a
span.

## Fixed trace fields

| Attribute | Meaning | Bound/classification |
| --- | --- | --- |
| `map.stage` | capture, validation, analysis, render, provider delivery, action validation, or cache | fixed low-cardinality enum |
| `map.duration_micros` | observed stage duration | integer, at most 600 seconds |
| `map.nodes`, `map.edges` | represented topology sizes | at most 1,024 / 8,192 at the presentation boundary |
| `map.graph_bytes`, `map.image_bytes` | validated serialized graph and PNG sizes | at most 2 MiB / 16 MiB |
| `map.cache_hit`, `map.stale`, `map.incomplete`, `map.image_capable`, `map.invalid_action` | bounded outcome flags | booleans; never an effect witness |
| `sts2.trajectory_digest` | optional decision linkage | keyed digest of a bounded opaque token, or `redacted` |

No node or run identifier becomes a metric label. Do not export map text,
images, base64, prompts, model output, rationale, game/provider credentials,
save data, or private paths as span attributes. Only approved sanitized
artifacts may be uploaded to MLflow under an existing experiment's approved
classification and retention policy; the adapter does not upload files
automatically.

Trajectory linkage uses domain-separated HMAC-SHA-256 with a fresh
operating-system-generated 256-bit key per exporter instance. Neither that key
nor the raw token is exported. Repeated tokens link only within that exporter
lifetime; restarts and separate exporters are intentionally unlinkable.
Cross-process correlation requires separately reviewed secret management.

## Evidence and rollback

Component testing must capture the actual HTTP body and reject invalid lineage,
oversized events, and unreachable Collector behavior. End-to-end acceptance
requires the adapter commit, deployed Collector/image identities, a sampled
sanitized span ID, and separately authorized retrieval from both MLflow and
Laminar. Missing query credentials remain a gate; neither port reachability nor
HTTP success proves backend storage.

Rollback disables the optional exporter and returns to local artifacts. It does
not restart services, change Collector configuration, rotate credentials, or
delete retained research artifacts.
