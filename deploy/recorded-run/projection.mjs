import { canonical, SCHEMA_DIGEST, WIRE_VERSION } from './validation.mjs';
import { STS, COMMON } from './bundle.mjs';
import { digest } from './store.mjs';

export const ADAPTER_VERSION = '0.1.0-candidate.1';
export function project(bundle) {
  const { manifest, omissions, events, accounting } = bundle;
  // The whole input has passed schema, archive, evidence and reconciliation
  // validation. Never persist an input filename, archive bytes or raw text.
  return {
    adapterVersion: ADAPTER_VERSION, contractSchemaDigest: SCHEMA_DIGEST, wireVersion: WIRE_VERSION,
    identity: manifest.recording.identity,
    semanticDigest: manifest.integrity.bundle_semantic_digest,
    identities: manifest.recording.identities,
    producer: manifest.producer, sourceAdapter: manifest.adapter, versions: manifest.versions,
    completeness: manifest.completeness, evidence: manifest.evidence,
    artifacts: manifest.entries,
    counts: { event_records: events.length, accounting_records: accounting.length,
      unsupported_records: events.filter(r => ![STS, COMMON].includes(r.payload.profile)).length,
      unknown_action_outcomes: events.filter(r => r.payload.kind === 'action_outcome'
        && r.evidence.action === 'unknown').length,
      settled_action_outcomes: events.filter(r => r.payload.kind === 'action_outcome'
        && r.evidence.action === 'settled').length },
    omissions,
    // Unknown optional content is retained only in its admitted digest envelope.
    records: events,
    accounting,
  };
}

function attribute(key, value) {
  const typed = typeof value === 'boolean' ? { boolValue: value }
    : typeof value === 'number' ? { intValue: String(value) }
      : { stringValue: typeof value === 'string' ? value : canonical(value) };
  return { key, value: typed };
}
function flatten(prefix, value, out = []) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, v] of Object.entries(value)) flatten(`${prefix}.${key}`, v, out);
  } else if (value !== null) out.push(attribute(prefix, value));
  // Null unknown usage deliberately has no numeric attribute. value_status,
  // scope and unit remain present and the exact null stays in local tracking.
  return out;
}

export function otlpBodies(runId, summary) {
  const time = String(BigInt(Date.now()) * 1000000n);
  const traceId = digest('recorded-run/trace\0' + runId).slice(0, 32);
  const rootId = digest('recorded-run/snapshot\0' + runId + '\0' + summary.semanticDigest).slice(0, 16);
  const makeSpan = (name, id, attributes, parentSpanId) => ({
    traceId, spanId: id, ...(parentSpanId ? { parentSpanId } : {}), name, kind: 1,
    // These are import spans. Original event times stay string attributes;
    // no artificial event duration or historical causal parent is invented.
    startTimeUnixNano: time, endTimeUnixNano: time,
    attributes: parentSpanId ? [attribute('recorded.semantic_digest', summary.semanticDigest),
      attribute('recorded.logical_run_key', runId), ...attributes] : attributes,
    status: { code: 0 },
  });
  const attrs = [attribute('recorded.mode', 'inspection'), attribute('recorded.execution_replay', false),
    attribute('recorded.logical_run_key', runId), attribute('recorded.semantic_digest', summary.semanticDigest),
    attribute('recorded.schema_digest', summary.contractSchemaDigest),
    attribute('recorded.adapter_version', ADAPTER_VERSION),
    ...flatten('recorded.identity', summary.identity), ...flatten('recorded.identities', summary.identities),
    ...flatten('recorded.evidence', summary.evidence), ...flatten('recorded.completeness', summary.completeness),
    ...flatten('recorded.counts', summary.counts), ...flatten('recorded.producer', summary.producer),
    ...flatten('recorded.source_adapter', summary.sourceAdapter), ...flatten('recorded.versions', summary.versions)];
  const spans = [makeSpan('recorded.snapshot', rootId, attrs)];
  const add = (name, key, attributes) => spans.push(makeSpan(name,
    digest(rootId + '\0' + key).slice(0, 16), attributes, rootId));
  for (const record of [...summary.records, ...summary.accounting]) {
    const supported = [STS, COMMON].includes(record.payload.profile);
    const attrs = [...flatten('recorded.source', record.source),
      ...flatten('recorded.identities', record.identities), ...flatten('recorded.evidence', record.evidence),
      attribute('recorded.supported', supported)];
    if (record.time) attrs.push(attribute('recorded.source_unix_ns', record.time.unix_ns));
    if (supported) flatten('recorded.payload', record.payload.value, attrs);
    // Opaque payload, including its optional-profile label, is never forwarded.
    add(supported ? `recorded.${record.payload.kind}` : 'recorded.unsupported',
      canonical([record.source.stream, record.source.record_ordinal, record.source.subrecord_ordinal]), attrs);
  }
  for (const artifact of summary.artifacts) add('recorded.artifact_reference', 'artifact:' + artifact.path,
    flatten('recorded.artifact', artifact));
  for (const stream of summary.omissions.streams) {
    const { dispositions, field_omissions, ...counts } = stream;
    add('recorded.stream_summary', 'stream:' + stream.stream, flatten('recorded.stream', counts));
  }
  const bodies = [];
  for (let i = 0; i < spans.length; i += 64) bodies.push({ resourceSpans: [{
    resource: { attributes: [attribute('service.name', 'ai-agent-observability-recorded-import')] },
    scopeSpans: [{ scope: { name: 'ai-ascension.recorded-run', version: ADAPTER_VERSION }, spans: spans.slice(i, i + 64) }],
  }] });
  return bodies;
}
