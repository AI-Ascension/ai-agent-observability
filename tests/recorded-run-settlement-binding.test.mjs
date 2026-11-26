import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ImportStore } from '../deploy/recorded-run/store.mjs';

const endpoint = 'https://example.invalid/collector';
function setup(t) {
  const store = new ImportStore(':memory:');
  t.after(() => store.close());
  const { runId, semanticDigest } = store.stage({
    identity: { namespace: 'test', value: 'settlement' }, semanticDigest: 'a'.repeat(64)
  }, () => [{ n: 0 }, { n: 1 }]);
  const claim = () => store.claim(runId, semanticDigest, endpoint);
  const snapshot = () => store.db.prepare('SELECT * FROM outbox ORDER BY part').all();
  return { store, claim, snapshot };
}
test('claim returns the committed sending row, not the pre-claim snapshot', t => {
  const { claim, snapshot } = setup(t);
  assert.deepEqual(claim(), snapshot()[0]);
});
for (const [name, sql] of [
  ['missing row', 'DELETE FROM outbox WHERE part=0'],
  ['changed payload', "UPDATE outbox SET body='{}' WHERE part=0"],
  ['changed endpoint', "UPDATE outbox SET endpoint='https://other.invalid/' WHERE part=0"],
  ['changed state', "UPDATE outbox SET state='unknown' WHERE part=0"]
]) {
  test(`settlement refuses ${name} without changing stored state`, t => {
    const { store, claim, snapshot } = setup(t);
    const row = claim();
    store.db.exec(sql);
    const before = snapshot();
    assert.throws(() => store.settle(row, 'acknowledged'), /delivery_settlement_conflict/);
    assert.deepEqual(snapshot(), before);
  });
}
test('repeated settlement does not falsely report a second transition', t => {
  const { store, claim, snapshot } = setup(t);
  const row = claim();
  store.settle(row, 'acknowledged');
  const before = snapshot();
  assert.throws(() => store.settle(row, 'acknowledged'), /delivery_settlement_conflict/);
  assert.deepEqual(snapshot(), before);
  assert.equal(claim().part, 1);
});
test('a bound claim can be settled unknown and remains reconciliation-required', t => {
  const { store, claim, snapshot } = setup(t);
  store.settle(claim(), 'unknown');
  assert.equal(snapshot()[0].state, 'unknown');
  assert.throws(claim, /delivery_reconciliation_required/);
});

test('durable claim can settle on a reopened store, but not twice', t => {
  const dir = mkdtempSync(join(tmpdir(), 'settlement-binding-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'owner.sqlite3');
  const first = new ImportStore(path);
  let row;
  try {
    const receipt = first.stage({ identity: { namespace: 'test', value: 'restart' },
      semanticDigest: 'b'.repeat(64) }, () => [{ n: 0 }]);
    row = first.claim(receipt.runId, receipt.semanticDigest, endpoint);
  } finally { first.close(); }
  const second = new ImportStore(path);
  try {
    second.settle(row, 'acknowledged');
    assert.throws(() => second.settle(row, 'acknowledged'), /delivery_settlement_conflict/);
    assert.equal(second.claim(row.run_id, row.digest, endpoint), undefined);
  } finally { second.close(); }
});
