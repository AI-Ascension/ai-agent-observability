import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateBundle, unknownEvidence } from '../deploy/recorded-run/bundle.mjs';
import { LIMITS, readZip } from '../deploy/recorded-run/validation.mjs';
import { fixture, bundleFor, zip } from './recorded-run-fixtures/build.mjs';

test('STS2 source binding rejects relocated kinds and diagnostics before reconciliation', () => {
  for (const example of [...fixture().events, ...fixture().accounting]) {
    const f = fixture();
    const r = [...f.events, ...f.accounting].find(r => r.source.stream === example.source.stream
      && r.source.record_ordinal === example.source.record_ordinal);
    r.source.stream = 'custom-owner';
    assert.throws(() => validateBundle(bundleFor(f)), /profile_source_stream/);
  }
});

test('unsupported diagnostics require digest, fixed source-free codes still validate', () => {
  for (const code of ['unsupported_source_event', 'unsupported_source_status']) {
    const f = fixture(), row = f.events.find(r => r.payload.value.code === 'operation_wait_completed');
    row.payload.value = { code };
    assert.throws(() => validateBundle(bundleFor(f)), /invalid_record/);
    row.payload.value.value_digest = 'a'.repeat(64);
    assert.doesNotThrow(() => validateBundle(bundleFor(f)));
  }
  assert.doesNotThrow(() => validateBundle(bundleFor(fixture())));
});

test('reason classes, owning streams and interrupted final-tail placement are enforced', () => {
  const classes = { raw_mcp_disallowed: 'filtered', private_source_metadata: 'filtered',
    unsupported_source_event: 'unsupported', unsupported_source_status: 'unsupported',
    invalid_source_record: 'rejected', partial_final_record: 'rejected' };
  for (const [reason, allowed] of Object.entries(classes)) {
    for (const disposition of ['filtered', 'unsupported', 'rejected'].filter(x => x !== allowed)) {
      const f = fixture(), stream = f.report.streams.find(s => s.stream === 'manifest');
      stream.dispositions[0] = { first: 0, last: 0, reason, disposition };
      assert.throws(() => validateBundle(bundleFor(f)), /invalid_omissions/);
    }
  }
  for (const reason of ['raw_mcp_disallowed', 'unsupported_source_event', 'unsupported_source_status', 'partial_final_record']) {
    const f = fixture(), stream = f.report.streams.find(s => s.stream === 'manifest');
    stream.dispositions[0] = { first: 0, last: 0, reason, disposition: classes[reason] };
    assert.throws(() => validateBundle(bundleFor(f)), /disposition_reason|partial_tail_disposition/);
  }
});

test('coincident model spelling retains independent namespaces and is valid', () => {
  const f = fixture();
  f.accounting[0].identities.model_execution.value = f.events.find(r => r.identities.model_execution)
    .identities.model_execution.value;
  const admitted = validateBundle(bundleFor(f));
  assert.notEqual(admitted.accounting[0].identities.model_execution.namespace,
    admitted.events.find(r => r.identities.model_execution).identities.model_execution.namespace);
});

function manyRecords(events, accounting) {
  const f = fixture();
  const make = (stream, n, payload) => Array.from({ length: n }, (_, record_ordinal) => ({
    profile: 'ai-ascension.recorded-run.common.v1',
    source: { stream, record_ordinal, subrecord_ordinal: 0 }, identities: {}, evidence: unknownEvidence(), payload }));
  f.events = make('decisions', events, { ...f.events[0].payload, value: { action_id_digests: [] } });
  f.accounting = make('provider-accounting', accounting, { ...f.accounting[0].payload,
    value: { source_schema: 'sts2.provider-accounting-v1', provider_execution_status: 'unknown',
      decision_status: 'unknown', counts: {}, usage: {} } });
  f.manifest.evidence = unknownEvidence();
  for (const stream of f.report.streams.filter(s => ['decisions', 'provider-accounting', 'trajectory', 'result'].includes(s.stream))) {
    const n = stream.stream === 'decisions' ? events : stream.stream === 'provider-accounting' ? accounting : 0;
    Object.assign(stream, { state: n ? 'present' : 'absent', input_records: n || null,
      emitted_rows: n, output_records: n, filtered_rows: 0, rejected_rows: 0, unsupported_rows: 0,
      dispositions: [], field_omissions: [] });
  }
  return f;
}

test('aggregate 25001 records rejects before any record JSON is materialized; 25000 passes', () => {
  const bytes = bundleFor(manyRecords(12500, 12501), true);
  const parse = JSON.parse; let materialized = 0;
  JSON.parse = function(text, ...args) {
    if (text.includes('"record_ordinal"')) materialized++;
    return parse(text, ...args);
  };
  try {
    assert.throws(() => validateBundle(bytes), /record_limit/);
    assert.equal(materialized, 0);
  } finally { JSON.parse = parse; }
  const admitted = validateBundle(bundleFor(manyRecords(12500, 12500), true));
  assert.equal(admitted.events.length + admitted.accounting.length, LIMITS.records);
});

test('oversized typed input has zero conversions; selected view excludes larger backing storage', () => {
  const oversized = new Uint8Array(LIMITS.archive + 1), from = Buffer.from;
  let conversions = 0;
  Buffer.from = function(...args) { conversions++; return from(...args); };
  try {
    assert.throws(() => readZip(oversized), /archive_byte_limit/);
    assert.equal(conversions, 0);
  } finally { Buffer.from = from; }
  const bytes = zip(new Map([['test.json', Buffer.from('{}')]]));
  const backing = new Uint8Array(LIMITS.archive + 100);
  backing.set(bytes, 37);
  const data = readZip(backing.subarray(37, 37 + bytes.length)).get('test.json');
  assert.equal(data.toString(), '{}'); assert.equal(data.buffer, backing.buffer);
  assert.throws(() => readZip(new Uint8Array(new SharedArrayBuffer(32))), /archive_byte_type/);
  assert.throws(() => readZip('invalid'), /archive_byte_type/);
});

test('candidate 2 artifact stays historical and is rejected by active candidate 3 consumer', () => {
  const bytes = readFileSync(new URL('../contract/recorded-run-bundle-v1/golden/legacy-failed.zip', import.meta.url));
  assert.throws(() => validateBundle(bytes), /invalid_manifest/);
});
