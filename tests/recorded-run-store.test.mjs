import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { ImportStore } from '../deploy/recorded-run/store.mjs';
import { collectorEndpoint, deliver } from '../deploy/recorded-run/delivery.mjs';

const snapshot = (semanticDigest = 'a'.repeat(64)) => ({
  identity: { namespace: 'synthetic.run', value: 'one' }, semanticDigest,
  accounting: [{ usage: { input_tokens: { status: 'unknown', unit: 'tokens' } } }],
});
const bodies = () => [{ resourceSpans: [] }];

test('SQLite persists one logical run, immutable revisions, and unknown usage across reopen', () => {
  const dir = mkdtempSync(join(tmpdir(), 'recorded-run-test-'));
  let store;
  try {
    const path = join(dir, 'imports.sqlite');
    store = new ImportStore(path);
    const first = store.stage(snapshot(), bodies);
    assert.equal(first.disposition, 'imported');
    assert.equal(store.stage(snapshot(), bodies).disposition, 'duplicate');
    const second = store.stage(snapshot('b'.repeat(64)), bodies);
    assert.equal(second.disposition, 'revision_added');
    assert.equal(first.runId, second.runId);
    store.close(); store = new ImportStore(path);
    assert.equal(store.db.prepare('SELECT count(*) AS n FROM runs').get().n, 1);
    const revisions = store.inspect(first.runId);
    assert.equal(revisions.length, 2);
    assert.deepEqual(revisions[0].accounting[0].usage.input_tokens, { status: 'unknown', unit: 'tokens' });
  } finally { store?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('failed projection rolls back the entire import transaction', () => {
  const store = new ImportStore(':memory:');
  assert.throws(() => store.stage(snapshot(), () => { throw new Error('failed'); }));
  assert.equal(store.db.prepare('SELECT count(*) AS n FROM runs').get().n, 0);
  store.close();
});

test('conflicting immutable producer, source identity and final evidence are rejected atomically', () => {
  const first = { ...snapshot(), producer: { name: 'producer', source_format: 'synthetic' },
    identities: { session: { namespace: 'session', value: 'one' } },
    evidence: { process_exit: 'completed', gameplay: 'episode_failed' } };
  const store = new ImportStore(':memory:');
  const row = store.stage(first, bodies);
  try {
    for (const mutate of [
      v => { v.producer.name = 'other'; },
      v => { v.identities.session.value = 'other'; },
      v => { v.evidence.gameplay = 'completed'; },
      v => { v.evidence.process_exit = 'failed'; },
    ]) {
      const next = structuredClone(first); next.semanticDigest = 'b'.repeat(64); mutate(next);
      assert.throws(() => store.stage(next, bodies), /conflict/);
      assert.equal(store.inspect(row.runId).length, 1);
    }
  } finally { store.close(); }
});

test('outbox serializes claims and never retries an uncertain send automatically', () => {
  const store = new ImportStore(':memory:');
  const value = store.stage(snapshot(), bodies);
  const row = store.claim(value.runId, value.semanticDigest, 'http://127.0.0.1:14318/v1/traces');
  assert.throws(() => store.claim(value.runId, value.semanticDigest, row.endpoint), /endpoint_conflict|reconciliation/);
  store.settle(row, 'unknown');
  assert.throws(() => store.claim(value.runId, value.semanticDigest, 'http://127.0.0.1:14318/v1/traces'), /reconciliation/);
  assert.equal(store.stage(snapshot(), bodies).disposition, 'duplicate');
  store.close();
});

test('delivery endpoint rejects public addresses, credentials, query strings and redirects', () => {
  for (const endpoint of ['https://example.com/v1/traces', 'http://localhost/v1/traces',
    'http://127.0.0.1/v1/traces?secret=x', 'http://user:secret@127.0.0.1/v1/traces',
    'http://127.0.0.1/api']) assert.throws(() => collectorEndpoint(endpoint));
  assert.equal(collectorEndpoint('http://127.0.0.1:14318/v1/traces'), 'http://127.0.0.1:14318/v1/traces');
});

test('mock OTLP acknowledgement and partial success have distinct durable outcomes', async () => {
  // Protocol transport test only; this server is not MLflow, Laminar, or Collector.
  let partial = false, requests = 0;
  const server = createServer(async (req, res) => {
    for await (const _ of req) { /* drain bounded test body */ }
    requests++;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(partial ? { partialSuccess: { rejectedSpans: '1' } } : {}));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${server.address().port}/v1/traces`;
  const store = new ImportStore(':memory:');
  try {
    const first = store.stage(snapshot(), bodies);
    const result = await deliver(store, first.runId, first.semanticDigest, endpoint);
    assert.equal(result.backendPersistence, 'unverified');
    await deliver(store, first.runId, first.semanticDigest, endpoint);
    assert.equal(requests, 1);
    partial = true;
    const second = store.stage(snapshot('b'.repeat(64)), bodies);
    await assert.rejects(deliver(store, second.runId, second.semanticDigest, endpoint), /reconciliation/);
    assert.equal(store.inspect(first.runId)[1].delivery[0].state, 'unknown');
  } finally { store.close(); await new Promise(resolve => server.close(resolve)); }
});
