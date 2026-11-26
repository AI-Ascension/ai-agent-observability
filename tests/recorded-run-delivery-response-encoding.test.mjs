import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ImportStore } from '../deploy/recorded-run/store.mjs';
import { deliver } from '../deploy/recorded-run/delivery.mjs';

const endpoint = 'http://127.0.0.1:4318/v1/traces';
function setup(t, chunks) {
  const store = new ImportStore(':memory:');
  t.after(() => store.close());
  const receipt = store.stage({ identity: { namespace: 'test', value: 'encoding' },
    semanticDigest: 'a'.repeat(64) }, () => [{ part: 0 }, { part: 1 }]);
  const fetch = t.mock.method(globalThis, 'fetch', async () => new Response(new ReadableStream({
    start(controller) { for (const chunk of chunks) controller.enqueue(chunk); controller.close(); },
  }), { headers: { 'content-type': 'application/json' } }));
  const run = () => deliver(store, receipt.runId, receipt.semanticDigest, endpoint);
  const states = () => store.db.prepare('SELECT state FROM outbox ORDER BY part').all().map(row => row.state);
  return { fetch, run, states };
}

for (const [name, bytes] of [
  ['invalid continuation', [0xc3, 0x28]],
  ['overlong sequence', [0xc0, 0xaf]],
  ['truncated sequence', [0xe2, 0x82]],
]) {
  test(`invalid UTF-8 ${name} cannot acknowledge a collector response`, async t => {
    const { fetch, run, states } = setup(t, [Buffer.from('{"extra":"'), Uint8Array.from(bytes), Buffer.from('"}')]);
    await assert.rejects(run(), /delivery_reconciliation_required/);
    assert.deepEqual(states(), ['unknown', 'pending']);
    await assert.rejects(run(), /delivery_reconciliation_required/);
    assert.equal(fetch.mock.callCount(), 1);
  });
}

test('valid UTF-8 spanning response chunks retains successful delivery', async t => {
  const { fetch, run, states } = setup(t, [Buffer.from('{"extra":"'), Uint8Array.of(0xc3), Uint8Array.of(0xa9), Buffer.from('"}')]);
  assert.deepEqual(await run(), { delivery: 'collector_acknowledged', acknowledgedParts: 2, backendPersistence: 'unverified' });
  assert.deepEqual(states(), ['acknowledged', 'acknowledged']);
  assert.equal(fetch.mock.callCount(), 2);
});

test('empty success object still acknowledges both parts', async t => {
  const { run, states } = setup(t, [Buffer.from('{}')]);
  assert.equal((await run()).acknowledgedParts, 2);
  assert.deepEqual(states(), ['acknowledged', 'acknowledged']);
});

test('BOM-prefixed response remains rejected', async t => {
  const { run, states } = setup(t, [Uint8Array.from([0xef, 0xbb, 0xbf]), Buffer.from('{}')]);
  await assert.rejects(run(), /delivery_reconciliation_required/);
  assert.deepEqual(states(), ['unknown', 'pending']);
});
