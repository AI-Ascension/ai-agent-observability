import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateBundle, COMMON, unknownEvidence } from '../deploy/recorded-run/bundle.mjs';
import { canonical, parseCanonical, LIMITS } from '../deploy/recorded-run/validation.mjs';
import { ImportStore } from '../deploy/recorded-run/store.mjs';
import { project, otlpBodies } from '../deploy/recorded-run/projection.mjs';
import { fixture, entriesFor, bundleFor, zip } from './recorded-run-fixtures/build.mjs';

test('shared synthetic source evidence projects two Unknown receipts, failed episode, distinct model executions', () => {
  const parsed = validateBundle(bundleFor(fixture()));
  const summary = project(parsed);
  assert.deepEqual(summary.counts, { event_records: 8, accounting_records: 1, unsupported_records: 0,
    unknown_action_outcomes: 2, settled_action_outcomes: 0 });
  assert.equal(summary.evidence.process_exit, 'completed');
  assert.equal(summary.evidence.gameplay, 'episode_failed');
  const trajectory = summary.records.find(r => r.identities.model_execution).identities.model_execution;
  const accounting = summary.accounting[0].identities.model_execution;
  assert.notEqual(trajectory.namespace, accounting.namespace);
  assert.notEqual(trajectory.value, accounting.value);
  const spans = otlpBodies('a'.repeat(64), summary).flatMap(b => b.resourceSpans[0].scopeSpans[0].spans);
  const account = spans.find(s => s.name === 'recorded.accounting');
  assert(!account.attributes.some(a => a.key === 'recorded.payload.usage.cached_input_tokens.value'));
  assert(account.attributes.some(a => a.key === 'recorded.payload.usage.cached_input_tokens.value_status'
    && a.value.stringValue === 'unknown'));
  const store = new ImportStore(':memory:');
  try {
    const first = store.stage(summary, otlpBodies);
    assert.equal(store.stage(project(validateBundle(bundleFor(fixture(), true))), otlpBodies).disposition, 'duplicate');
    assert.equal(store.inspect(first.runId).length, 1);
  } finally { store.close(); }
});

test('missing optional accounting is absent, never a fabricated zero', () => {
  const f = fixture(); f.accounting = null;
  Object.assign(f.report.streams.find(s => s.stream === 'provider-accounting'), { state: 'absent', input_records: null,
    emitted_rows: 0, output_records: 0 });
  const summary = project(validateBundle(bundleFor(f)));
  assert.deepEqual(summary.accounting, []);
  assert.equal(summary.omissions.streams.find(s => s.stream === 'provider-accounting').state, 'absent');
});

test('candidate 2 public player counters remain decimal strings and extra player text rejects', () => {
  const f = fixture();
  const row = f.events.find(r => r.source.stream === 'trajectory' && r.payload.kind === 'decision_summary');
  row.payload.value.observation = { generation: '8', state_id_digest: 'a'.repeat(64),
    observation_digest: 'b'.repeat(64), legal_action_count: 3,
    player: { hp: '44', max_hp: '80', energy: '2', gold: '9007199254740993' } };
  const summary = project(validateBundle(bundleFor(f)));
  const wire = otlpBodies('a'.repeat(64), summary);
  const attrs = wire.flatMap(b => b.resourceSpans[0].scopeSpans[0].spans).flatMap(s => s.attributes);
  assert(attrs.some(a => a.key === 'recorded.payload.observation.player.gold'
    && a.value.stringValue === '9007199254740993'));
  row.payload.value.observation.player.name = 'PRIVATE_PROMPT_SENTINEL';
  assert.throws(() => validateBundle(bundleFor(f)), /invalid_record/);
});

test('optional unknown profile is inert; required unknown profile rejects', () => {
  const f = fixture(); f.manifest.optional_profiles = ['synthetic.future.v2'];
  const r = f.events.find(r => r.source.stream === 'decisions');
  r.payload = { profile: 'synthetic.future.v2', kind: 'opaque', value: {
    content_digest: 'c'.repeat(64), bytes: 17, media_type: 'application/json' } };
  const summary = project(validateBundle(bundleFor(f)));
  assert.equal(summary.counts.unsupported_records, 1);
  assert(!JSON.stringify(otlpBodies('a'.repeat(64), summary)).includes('synthetic.future.v2'));
  f.manifest.optional_profiles = []; f.manifest.required_profiles.push('synthetic.future.v2');
  assert.throws(() => validateBundle(bundleFor(f)), /profile/);
});

test('cannot claim settlement, successful gameplay or matching execution namespace from Train evidence', () => {
  for (const mutate of [
    f => { f.events.find(r => r.payload.kind === 'action_outcome').payload.value.status = 'settled'; },
    f => { f.events.find(r => r.payload.kind === 'action_outcome').evidence.action = 'settled'; },
    f => { f.manifest.evidence.gameplay = 'completed'; },
    f => { f.accounting[0].identities.model_execution.namespace = 'seed-readiness.trajectory.model-execution'; },
    f => { f.accounting[0].payload.value.usage.cached_input_tokens.value = '0'; },
    f => { f.accounting[0].payload.value.usage.input_tokens.value = null; },
    f => { f.events.push(f.accounting[0]); },
  ]) {
    const f = fixture(); mutate(f); assert.throws(() => validateBundle(bundleFor(f)));
  }
});

test('no raw secrets, private paths, unadmitted fields, or partial JSONL enter tracking', () => {
  for (const secret of ['PRIVATE_PROMPT_SENTINEL', 'BEARER_TOKEN_SENTINEL', 'C:\\Users\\private\\save']) {
    const f = fixture(); f.accounting[0].payload.value.raw_output = secret;
    assert.throws(() => validateBundle(bundleFor(f)), /invalid_record/);
    delete f.accounting[0].payload.value.raw_output;
    f.manifest.recording.identity.value = '/private/' + secret;
    assert.throws(() => validateBundle(bundleFor(f)), /invalid_manifest/);
  }
  const entries = entriesFor(fixture());
  entries.set('records/events.ndjson', entries.get('records/events.ndjson').subarray(0, -1));
  assert.throws(() => validateBundle(zip(entries)), /entry_integrity/);
});

test('JCS rejects ambiguous encodings and preserves numeric-like keys and nanoseconds', () => {
  assert.equal(canonical({ '2': 2, '10': 10, annotations: {} }), '{"10":10,"2":2,"annotations":{}}');
  for (const value of ['{"a":1,"a":2}', '{"a":1,"\\u0061":2}', '{"x":"\\ud800"}',
    '{"n":9007199254740993}', '{"n":-0}', ' {"a":1}', '\ufeff{}', '[1,2]\n'])
    assert.throws(() => parseCanonical(Buffer.from(value), 1024));
  const parsed = validateBundle(bundleFor(fixture()));
  assert.equal(parsed.events[0].time.unix_ns, '1789090000123456789');
  assert.throws(() => parseCanonical(Buffer.from('['.repeat(33) + '0' + ']'.repeat(33)), 1024), /depth/);
});

test('manifest and unknown optional identities cannot bypass privacy or token-control checks', () => {
  const f = fixture();
  f.manifest.recording.identities.action = { namespace: 'private.action', value: 'PRIVATE_ACTION' };
  assert.throws(() => validateBundle(bundleFor(f)), /identity_privacy/);
  delete f.manifest.recording.identities.action;
  f.manifest.optional_profiles = ['future.optional.v1'];
  f.events[0].payload = { profile: 'future.optional.v1', kind: 'opaque', value: {
    content_digest: 'a'.repeat(64), bytes: 1, media_type: 'application/json' } };
  f.events[0].identities.provider_request = { namespace: 'private.provider', value: 'SECRET_REQUEST' };
  assert.throws(() => validateBundle(bundleFor(f)), /identity_privacy/);
  delete f.events[0].identities.provider_request;
  f.manifest.recording.identity.value += '\n';
  assert.throws(() => validateBundle(bundleFor(f)), /profile_control_character/);
});

test('ZIP rejects traversal, duplicate names, symlinks, mismatched headers, oversized expansion and tampering', () => {
  const entries = entriesFor(fixture());
  entries.set('../escape', Buffer.from('x'));
  assert.throws(() => validateBundle(zip(entries)), /zip_path/);
  entries.delete('../escape');
  const duplicates = [...entries, [...entries][0]]; duplicates.size = duplicates.length;
  assert.throws(() => validateBundle(zip(duplicates)), /zip_path/);
  const bytes = zip(entries), directory = bytes.readUInt32LE(bytes.length - 6);
  const symlink = Buffer.from(bytes); symlink.writeUInt16LE(0x314, directory + 4); symlink.writeUInt32LE(0xa1ff0000, directory + 38);
  assert.throws(() => validateBundle(symlink), /zip_not_regular/);
  const badName = Buffer.from(bytes); badName[30] = 120;
  assert.throws(() => validateBundle(badName), /zip_name_mismatch/);
  const corrupt = Buffer.from(bytes); corrupt[100] ^= 1;
  assert.throws(() => validateBundle(corrupt));
  const huge = new Map([['manifest.json', Buffer.alloc(LIMITS.manifest + 1, 32)]]);
  assert.throws(() => validateBundle(zip(huge, true)), /zip_expanded_limit/);
  const badCount = Buffer.from(bytes); badCount.writeUInt16LE(33, bytes.length - 12);
  assert.throws(() => validateBundle(badCount), /zip_directory/);
});

test('reconciliation rejects duplicate ordinals, overlapping dispositions and inflated summary counts', () => {
  for (const mutate of [
    f => { f.events[1].source = structuredClone(f.events[0].source); },
    f => { f.report.streams[0].output_records++; },
    f => { f.report.streams[0].dispositions = [{ first: 0, last: 0, disposition: 'filtered', reason: 'private_source_metadata' }]; },
    f => { f.events[0].source.subrecord_ordinal = 1; },
    f => { f.events[0].time.unix_ns = 1789090000123456789; },
    f => { f.manifest.format_version = '2.0.0'; },
  ]) { const f = fixture(); mutate(f); assert.throws(() => validateBundle(bundleFor(f))); }
});
