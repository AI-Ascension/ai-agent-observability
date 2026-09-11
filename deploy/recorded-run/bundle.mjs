import { openSync, fstatSync, readSync, closeSync, constants } from 'node:fs';
import { canonical, parseCanonical, readZip, validateDocument, requireThat as check,
  LIMITS, SCHEMA_DIGEST } from './validation.mjs';
import { digest } from './store.mjs';

export const COMMON = 'ai-ascension.recorded-run.common.v1';
export const STS = 'ai-ascension.sts2.seed-readiness.v1';
export const unknownEvidence = () => ({ process_exit: 'unknown', request: 'unknown',
  action: 'unknown', outcome: 'unknown', gameplay: 'unknown' });
const same = (a, b) => canonical(a) === canonical(b);
const sorted = values => values.every((v, i) => i === 0 || values[i - 1] < v);
const sourceStreams = ['trajectory', 'decisions', 'mcp', 'provider-accounting', 'result', 'manifest'];
const kindStreams = { seed_start: ['trajectory'], observation_summary: ['trajectory'],
  action_outcome: ['trajectory'], decision_summary: ['trajectory', 'decisions'],
  accounting: ['provider-accounting'], process_result: ['result'] };
const diagnosticStreams = { operation_wait_completed: ['trajectory'], episode_failed: ['trajectory'],
  unsupported_source_event: ['trajectory'], unsupported_source_status: ['trajectory', 'provider-accounting'],
  invalid_source_record: sourceStreams, partial_final_record: sourceStreams, unsupported_profile: sourceStreams };
const reasonRules = { raw_mcp_disallowed: ['filtered', ['mcp']],
  private_source_metadata: ['filtered', ['manifest']], unsupported_source_event: ['unsupported', ['trajectory']],
  unsupported_source_status: ['unsupported', ['trajectory', 'provider-accounting']],
  invalid_source_record: ['rejected', null], partial_final_record: ['rejected', null] };
function identityPrivacy(identities) {
  for (const [key, namespace] of [['action', 'ai-ascension.action.sha256'],
    ['provider_request', 'ai-ascension.provider-request.sha256']]) {
    const identity = identities[key];
    if (identity) check(identity.namespace === namespace && /^[a-f0-9]{64}$/.test(identity.value), 'identity_privacy');
  }
}
export function semanticDigest(manifest) {
  const copy = structuredClone(manifest);
  delete copy.integrity.bundle_semantic_digest;
  return digest(canonical(copy));
}

function recordSemantics(record, manifest) {
  const { profile, kind, value } = record.payload;
  identityPrivacy(record.identities);
  check([...manifest.required_profiles, ...manifest.optional_profiles].includes(profile), 'undeclared_profile');
  const evidence = unknownEvidence();
  if (profile === COMMON && kind === 'gameplay_result') {
    check(manifest.producer.source_format !== 'seed-readiness-controller-release-v2', 'legacy_gameplay_overclaim');
    evidence.gameplay = 'completed'; evidence.outcome = 'observed';
    check(same(record.evidence, evidence), 'gameplay_evidence');
    return;
  }
  if (profile !== STS) {
    check(profile !== COMMON && manifest.optional_profiles.includes(profile)
      && kind === 'opaque' && same(record.evidence, evidence), 'unsupported_profile_envelope');
    return;
  }
  check(kind !== 'opaque', 'known_profile_opaque');
  check((kind === 'diagnostic' ? diagnosticStreams[value.code] : kindStreams[kind])
    ?.includes(record.source.stream), 'profile_source_stream');
  if (kind === 'diagnostic' && ['unsupported_source_event', 'unsupported_source_status'].includes(value.code))
    check(typeof value.value_digest === 'string' && /^[a-f0-9]{64}$/.test(value.value_digest), 'diagnostic_digest');
  if (kind === 'process_result') evidence.process_exit = value.exit_code === 0 ? 'completed' : 'failed';
  if (kind === 'diagnostic' && value.code === 'episode_failed') evidence.gameplay = 'episode_failed';
  if (kind === 'seed_start') {
    evidence.action = value.status;
    if (['accepted', 'settled'].includes(value.status)) evidence.request = 'accepted';
    if (value.status === 'rejected') evidence.request = 'rejected';
    if (value.status === 'settled') {
      check(value.run_started && value.host_ready && value.effect_kind === 'run_started'
        && record.identities.operation, 'seed_settlement');
      evidence.outcome = 'observed';
    } else check(value.effect_kind === 'unknown' && !value.run_started, 'seed_unsettled_witness');
    check(value.seed_match === (value.requested_seed_digest === value.canonical_seed_digest), 'seed_match');
  }
  if (kind === 'action_outcome') {
    // Actual Train receipts are Unknown with null effects. This profile admits
    // no settled action receipt, irrespective of provider/process completion.
    check(value.status === 'unknown' && !value.observation && !value.from_generation
      && !value.to_generation && !value.effect_digest, 'unadmitted_action_settlement');
  }
  if (kind === 'accounting') {
    check(record.source.stream === 'provider-accounting', 'accounting_stream');
    for (const usage of Object.values(value.usage)) {
      check(['unknown', 'not_applicable'].includes(usage.value_status) === (usage.value === null), 'unknown_usage');
    }
    if (value.counts.completed_turn_count !== undefined && value.counts.turn_count !== undefined)
      check(BigInt(value.counts.completed_turn_count) <= BigInt(value.counts.turn_count), 'accounting_turns');
  }
  if (record.identities.model_execution) check(record.identities.model_execution.namespace ===
    (kind === 'accounting' ? 'seed-readiness.accounting.model-execution'
      : 'seed-readiness.trajectory.model-execution'), 'model_execution_namespace');
  check(same(record.evidence, evidence), 'evidence_mismatch');
}

function reconcile(manifest, report, records) {
  const streams = report.streams;
  check(sorted(streams.map(s => s.stream)), 'stream_order');
  for (const name of ['trajectory', 'decisions', 'mcp', 'provider-accounting', 'result', 'manifest'])
    check(streams.some(s => s.stream === name), 'missing_stream_disposition');
  check(records.every(r => streams.some(s => s.stream === r.source.stream)), 'undeclared_stream');
  for (const stream of streams) {
    const output = records.filter(r => r.source.stream === stream.stream);
    const emitted = new Set(output.map(r => r.source.record_ordinal));
    check(output.length === stream.output_records && emitted.size === stream.emitted_rows, 'output_counts');
    if (['absent', 'unknown'].includes(stream.state)) {
      check(stream.input_records === null && stream.emitted_rows + stream.filtered_rows + stream.unsupported_rows
        + stream.rejected_rows + stream.output_records === 0 && !stream.dispositions.length
        && !stream.field_omissions.length, 'absent_counts');
      continue;
    }
    check(stream.input_records !== null, 'missing_input_count');
    const covered = new Set(emitted), counts = { filtered: 0, unsupported: 0, rejected: 0 };
    check([...covered].every(n => n < stream.input_records), 'source_ordinal');
    let last = -1;
    for (const range of stream.dispositions) {
      const rule = reasonRules[range.reason];
      check(rule && range.disposition === rule[0] && (!rule[1] || rule[1].includes(stream.stream)), 'disposition_reason');
      if (range.reason === 'partial_final_record') check(stream.state === 'interrupted'
        && range.first === range.last && range.last === stream.input_records - 1, 'partial_tail_disposition');
      check(range.first <= range.last && range.first > last && range.last < stream.input_records, 'disposition_range');
      last = range.last;
      for (let n = range.first; n <= range.last; n++) {
        check(!covered.has(n), 'disposition_overlap');
        covered.add(n); counts[range.disposition]++;
      }
    }
    check(covered.size === stream.input_records && counts.filtered === stream.filtered_rows
      && counts.unsupported === stream.unsupported_rows && counts.rejected === stream.rejected_rows, 'reconciliation');
    check(stream.emitted_rows + stream.filtered_rows + stream.unsupported_rows + stream.rejected_rows
      === stream.input_records, 'row_arithmetic');
    check(stream.field_omissions.every(f => f.affected_rows <= stream.input_records)
      && new Set(stream.field_omissions.map(f => f.rule)).size === stream.field_omissions.length, 'field_omissions');
    if (stream.state === 'omitted') check(stream.filtered_rows === stream.input_records, 'omitted_state');
    if (stream.state === 'unsupported') check(stream.unsupported_rows === stream.input_records, 'unsupported_state');
    if (stream.state === 'interrupted') check(stream.dispositions.some(d => d.reason === 'partial_final_record'
      && d.disposition === 'rejected' && d.first === d.last && d.last === stream.input_records - 1), 'interrupted_tail');
    if (stream.stream === 'mcp') check(!stream.emitted_rows && stream.filtered_rows === stream.input_records
      && stream.dispositions.every(d => d.reason === 'raw_mcp_disallowed'), 'mcp_disallowed');
  }
  const evidence = unknownEvidence();
  const exits = records.filter(r => r.payload.kind === 'process_result');
  check(exits.length <= 1, 'duplicate_process_result');
  if (exits.length) evidence.process_exit = exits[0].evidence.process_exit;
  if (records.some(r => r.payload.kind === 'diagnostic' && r.payload.value.code === 'episode_failed'))
    evidence.gameplay = 'episode_failed';
  if (records.some(r => r.payload.kind === 'gameplay_result')) {
    check(evidence.gameplay !== 'episode_failed', 'conflicting_gameplay_evidence');
    evidence.gameplay = 'completed'; evidence.outcome = 'observed';
  }
  check(same(manifest.evidence, evidence), 'summary_evidence');
  if (manifest.completeness.status === 'complete') check(manifest.completeness.source_snapshot === 'stable'
    && streams.every(s => !['unknown', 'interrupted', 'unsupported'].includes(s.state)
      && !s.rejected_rows && !s.unsupported_rows), 'completeness_overclaim');
}

export function validateBundle(bytes) {
  const entries = readZip(bytes);
  check(entries.has('manifest.json'), 'missing_manifest');
  const manifest = parseCanonical(entries.get('manifest.json'), LIMITS.manifest);
  validateDocument(manifest, 'manifest');
  identityPrivacy(manifest.recording.identities);
  check(manifest.contract_schema_sha256 === SCHEMA_DIGEST, 'contract_digest');
  check(sorted(manifest.required_profiles) && sorted(manifest.optional_profiles)
    && manifest.required_profiles.includes(COMMON) && manifest.required_profiles.every(p => [COMMON, STS].includes(p))
    && !manifest.optional_profiles.some(p => manifest.required_profiles.includes(p)), 'unsupported_or_duplicate_profile');
  check(manifest.integrity.bundle_semantic_digest === semanticDigest(manifest), 'semantic_digest');
  check(manifest.bundle_id === digest('ai-ascension.recorded-run.v1/bundle-id\0' + canonical(manifest.recording.identity)), 'bundle_identity');
  const names = manifest.entries.map(e => e.path);
  check(sorted(names) && names.includes('records/events.ndjson') && names.includes('reports/omissions.json')
    && entries.size === names.length + 1, 'required_or_duplicate_entries');
  for (const entry of manifest.entries) {
    const data = entries.get(entry.path);
    check(data && data.length === entry.bytes && digest(data) === entry.sha256, 'entry_integrity');
    check(entry.media_type === (entry.path.endsWith('.ndjson') ? 'application/x-ndjson' : 'application/json'), 'entry_media');
  }
  const omissions = parseCanonical(entries.get('reports/omissions.json'), LIMITS.omissions);
  validateDocument(omissions, 'omissions');
  // Scan both files before materializing any record, using one aggregate budget.
  let preflightCount = 0;
  for (const path of ['records/events.ndjson', 'records/accounting.ndjson']) {
    const data = entries.get(path) ?? Buffer.alloc(0);
    check(!data.length || data.at(-1) === 10, 'partial_final_record');
    let start = 0;
    for (let end = 0; end < data.length; end++) {
      check(end - start <= LIMITS.line, 'json_byte_limit');
      if (data[end] === 10) {
        check(end > start && ++preflightCount <= LIMITS.records, 'record_limit');
        start = end + 1;
      }
    }
  }
  let count = 0;
  function records(path) {
    const data = entries.get(path) ?? Buffer.alloc(0), result = [];
    check(!data.length || data.at(-1) === 10, 'partial_final_record');
    let start = 0, previous, sub = new Map();
    for (let end = 0; end < data.length; end++) if (data[end] === 10) {
      check(end > start && ++count <= LIMITS.records, 'record_limit');
      const record = parseCanonical(data.subarray(start, end), LIMITS.line);
      validateDocument(record, 'record'); recordSemantics(record, manifest);
      const s = record.source, key = canonical([s.stream, s.record_ordinal]);
      check(s.subrecord_ordinal === (sub.get(key) ?? 0), 'subrecord_order');
      sub.set(key, s.subrecord_ordinal + 1);
      if (previous) check(s.stream > previous.stream || (s.stream === previous.stream
        && (s.record_ordinal > previous.record_ordinal || (s.record_ordinal === previous.record_ordinal
          && s.subrecord_ordinal > previous.subrecord_ordinal))), 'record_order');
      previous = s; result.push(record); start = end + 1;
    }
    return result;
  }
  const events = records('records/events.ndjson'), accounting = records('records/accounting.ndjson');
  check(events.every(r => r.payload.kind !== 'accounting') && accounting.every(r => r.payload.kind === 'accounting'), 'accounting_authority');
  const all = [...events, ...accounting];
  check(new Set(all.map(r => canonical([r.source.stream, r.source.record_ordinal, r.source.subrecord_ordinal]))).size === all.length, 'duplicate_record');
  reconcile(manifest, omissions, all);
  return { manifest, omissions, events, accounting };
}

export function readBundle(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const before = fstatSync(fd);
    check(before.isFile() && before.size <= LIMITS.archive, 'archive_file_limit');
    const bytes = Buffer.alloc(before.size);
    let offset = 0;
    while (offset < bytes.length) {
      const size = readSync(fd, bytes, offset, bytes.length - offset, null);
      check(size > 0, 'source_file_changed'); offset += size;
    }
    const after = fstatSync(fd);
    check(before.size === after.size && before.mtimeMs === after.mtimeMs, 'source_file_changed');
    return validateBundle(bytes);
  } finally { closeSync(fd); }
}
