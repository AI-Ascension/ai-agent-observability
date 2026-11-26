import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ImportStore } from '../deploy/recorded-run/store.mjs';
import { deliver } from '../deploy/recorded-run/delivery.mjs';
import { importBundle } from '../deploy/recorded-run/import.mjs';

const endpoint = 'http://127.0.0.1:4318/v1/traces';
const ok = () => new Response('{}', { headers: { 'content-type': 'application/json' } });
const reconcile = { message: 'delivery_reconciliation_required' };
function setup(t) {
  const store = new ImportStore(':memory:');
  t.after(() => store.close());
  const receipt = store.stage({identity: {namespace: 'test', value: 'delivery'},
    semanticDigest: 'a'.repeat(64)}, () => [{part: 0}, {part: 1}]);
  const calls = [];
  const settle = store.settle.bind(store);
  t.mock.method(store, 'settle', (row, state) => { calls.push(state); return settle(row, state); });
  const send = () => deliver(store, receipt.runId, receipt.semanticDigest, endpoint);
  const states = () => store.db.prepare('SELECT state FROM outbox ORDER BY part').all().map(r => r.state);
  return {store, receipt, calls, send, states};
}

test('accepted response with a stale durable claim makes one settlement attempt and stops', async t => {
  const {store, calls, send, states} = setup(t);
  const fetch = t.mock.method(globalThis, 'fetch', async () => {
    store.db.exec("UPDATE outbox SET body='{}' WHERE part=0");
    return ok();
  });
  await assert.rejects(send(), reconcile);
  assert.deepEqual(calls, ['acknowledged']);
  assert.deepEqual(states(), ['sending', 'pending']);
  assert.equal(fetch.mock.callCount(), 1);
});

test('transport failure with a changed claim exposes reconciliation, not the internal settlement error', async t => {
  const {store, calls, send, states} = setup(t);
  const fetch = t.mock.method(globalThis, 'fetch', async () => {
    store.db.exec("UPDATE outbox SET body='{}' WHERE part=0");
    throw Error('synthetic transport failure');
  });
  await assert.rejects(send(), reconcile);
  assert.deepEqual(calls, ['unknown']);
  assert.deepEqual(states(), ['sending', 'pending']);
  assert.equal(fetch.mock.callCount(), 1);
});

test('ambiguous acknowledgment commit never attempts a second transition', async t => {
  const {store, calls, send, states} = setup(t);
  const wrapped = store.settle.bind(store);
  t.mock.method(store, 'settle', (row, state) => {
    wrapped(row, state);
    throw Error('synthetic post-commit failure');
  });
  const fetch = t.mock.method(globalThis, 'fetch', async () => ok());
  await assert.rejects(send(), reconcile);
  assert.deepEqual(calls, ['acknowledged']);
  assert.deepEqual(states(), ['acknowledged', 'pending']);
  assert.equal(fetch.mock.callCount(), 1);
});

test('transport failure commits unknown once and prevents automatic resend', async t => {
  const {calls, send, states} = setup(t);
  const fetch = t.mock.method(globalThis, 'fetch', async () => { throw Error('synthetic failure'); });
  await assert.rejects(send(), reconcile);
  await assert.rejects(send(), reconcile);
  assert.deepEqual(calls, ['unknown']);
  assert.deepEqual(states(), ['unknown', 'pending']);
  assert.equal(fetch.mock.callCount(), 1);
});

test('actual archived bundle import sends precisely the stored projection in order', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'delivery-integration-'));
  t.after(() => rmSync(dir, {recursive: true, force: true}));
  const path = join(dir, 'owner.sqlite3');
  const receipt = importBundle(new URL('../contract/recorded-run-bundle-v1-candidate3/golden/legacy-failed.zip', import.meta.url), path);
  const store = new ImportStore(path);
  t.after(() => store.close());
  const expected = store.db.prepare('SELECT body FROM outbox ORDER BY part').all().map(r => r.body);
  const observed = [];
  t.mock.method(globalThis, 'fetch', async (url, opts) => {
    assert.equal(url, endpoint);
    assert.equal(opts.redirect, 'error');
    observed.push(opts.body);
    return ok();
  });
  assert.ok(expected.length > 0);
  assert.equal(store.inspectLocalImport(receipt.runId, receipt.semanticDigest).localOnly, true);
  assert.deepEqual(await deliver(store, receipt.runId, receipt.semanticDigest, endpoint), {
    delivery: 'collector_acknowledged', acknowledgedParts: expected.length, backendPersistence: 'unverified'
  });
  assert.deepEqual(observed, expected);
  assert.equal(store.inspectLocalImport(receipt.runId, receipt.semanticDigest).localOnly, false);
  assert.deepEqual(await deliver(store, receipt.runId, receipt.semanticDigest, endpoint), {
    delivery: 'already_acknowledged', acknowledgedParts: 0, backendPersistence: 'unverified'
  });
  assert.deepEqual(observed, expected);
});
