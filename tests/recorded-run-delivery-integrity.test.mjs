import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ImportStore } from '../deploy/recorded-run/store.mjs';

const endpoint = 'https://example.invalid/never-contacted';
function setup(t) {
  const dir = mkdtempSync(join(tmpdir(), 'outbox-claim-'));
  const store = new ImportStore(join(dir, 'owner.sqlite3'));
  t.after(() => { store.close(); rmSync(dir, { recursive: true, force: true }); });
  const receipt = store.stage({identity: {namespace: 'test', value: 'run'},
    semanticDigest: 'a'.repeat(64)}, () => [{n: 0}, {n: 1}, {n: 2}]);
  return {store, receipt};
}
function claim(store, receipt) { return store.claim(receipt.runId, receipt.semanticDigest, endpoint); }
function states(store) { return store.db.prepare('SELECT part,state,endpoint FROM outbox ORDER BY part').all().map(row => [row.part,row.state,row.endpoint]); }
for (const [name, sql] of [
  ['truncated contiguous suffix', 'DELETE FROM outbox WHERE part=2'],
  ['mutated body', "UPDATE outbox SET body='{}' WHERE part=1"],
  ['renumbered part', 'UPDATE outbox SET part=9 WHERE part=2'],
  ['inserted part', "INSERT INTO outbox SELECT run_id,digest,3,body,NULL,'pending' FROM outbox WHERE part=0"]
]) {
  test(`manifested delivery refuses ${name} before claiming any part`, t => {
    const {store, receipt} = setup(t);
    store.db.exec(sql);
    const before = states(store);
    assert.throws(() => claim(store, receipt), /delivery_projection_integrity_conflict/);
    assert.deepEqual(states(store), before);
  });
}
test('normal ordered claims and acknowledgements retain original manifest', t => {
  const {store, receipt} = setup(t);
  const before = store.db.prepare('SELECT * FROM local_import_manifest').all();
  for (let i=0;i<3;i++) {
    const row = claim(store, receipt);
    assert.equal(row.part, i);
    store.settle(row, 'acknowledged');
  }
  assert.equal(claim(store, receipt), undefined);
  assert.deepEqual(store.db.prepare('SELECT * FROM local_import_manifest').all(), before);
});
test('after partial acknowledgment a damaged remainder cannot be claimed', t => {
  const {store, receipt} = setup(t);
  store.settle(claim(store, receipt), 'acknowledged');
  store.db.exec('DELETE FROM outbox WHERE part=2');
  const before = states(store);
  assert.throws(() => claim(store, receipt), /delivery_projection_integrity_conflict/);
  assert.deepEqual(states(store), before);
});
test('legacy unmanifested revision preserves existing delivery behavior, not attestation', t => {
  const {store, receipt} = setup(t);
  store.db.exec('DELETE FROM local_import_manifest');
  assert.equal(store.inspectLocalImport(receipt.runId,receipt.semanticDigest).localOnly,false);
  assert.equal(claim(store, receipt).part,0);
});
test('unknown delivery remains reconciliation-required', t => {
  const {store, receipt} = setup(t);
  store.settle(claim(store, receipt), 'unknown');
  assert.throws(() => claim(store, receipt), /delivery_reconciliation_required/);
});
