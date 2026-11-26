import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { importBundleBytes } from '../deploy/recorded-run/import.mjs';
import { ImportStore } from '../deploy/recorded-run/store.mjs';

const input = readFileSync(new URL('../contract/recorded-run-bundle-v1-candidate3/golden/legacy-failed.zip', import.meta.url));
function database(t) {
  const directory = mkdtempSync(join(tmpdir(), 'local-import-witness-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return join(directory, 'recorded.sqlite3');
}
function witness(path, receipt) {
  const store = new ImportStore(path, { readOnly: true });
  try { return store.inspectLocalImport(receipt.runId, receipt.semanticDigest); }
  finally { store.close(); }
}

test('read-only import witness attests an unchanged single revision and unbound pending outbox', t => {
  const db = database(t);
  const first = importBundleBytes(input, db);
  const before = witness(db, first);
  assert.equal(before.localOnly, true);
  assert.equal(before.revisions.length, 1);
  assert.equal(importBundleBytes(input, db).disposition, 'duplicate');
  assert.deepEqual(witness(db, first), before);
  assert.equal(witness(db, {...first, semanticDigest: 'wrong-digest'}).localOnly, false);
});

test('pending delivery with an assigned endpoint is not local-only and endpoint stays private', t => {
  const db = database(t);
  const first = importBundleBytes(input, db);
  const sql = new DatabaseSync(db);
  try {
    const endpoint = 'https://example.invalid/synthetic-delivery';
    sql.prepare('UPDATE outbox SET endpoint=? WHERE part=0').run(endpoint);
    const result = witness(db, first);
    assert.ok(result.revisions[0].delivery.every(row => row.state === 'pending'));
    assert.equal(result.localOnly, false);
    assert.ok(!JSON.stringify(result).includes(endpoint));
    sql.prepare("UPDATE outbox SET endpoint='' WHERE part=0").run();
    assert.equal(witness(db, first).localOnly, false);
    sql.prepare('UPDATE outbox SET endpoint=NULL WHERE part=0').run();
    assert.equal(witness(db, first).localOnly, true);
    sql.prepare("UPDATE outbox SET state='unknown' WHERE part=0").run();
    assert.equal(witness(db, first).localOnly, false);
  } finally { sql.close(); }
});

test('a missing or noncontiguous outbox cannot produce a local-only witness', t => {
  const db = database(t);
  const first = importBundleBytes(input, db);
  const sql = new DatabaseSync(db);
  try {
    sql.prepare('UPDATE outbox SET part=part+100').run();
    assert.equal(witness(db, first).localOnly, false);
    sql.prepare('DELETE FROM outbox').run();
    assert.equal(witness(db, first).localOnly, false);
  } finally { sql.close(); }
});

test('a contiguous prefix of a multi-part staged outbox is not complete', t => {
  const db = database(t);
  const store = new ImportStore(db);
  const summary = { identity: { namespace: 'synthetic', value: 'multi-part' }, semanticDigest: 'a'.repeat(64) };
  let receipt;
  try { receipt = store.stage(summary, () => [{ part: 0 }, { part: 1 }, { part: 2 }]); }
  finally { store.close(); }
  assert.equal(witness(db, receipt).localOnly, true);
  const sql = new DatabaseSync(db);
  try { sql.prepare('DELETE FROM outbox WHERE part=2').run(); }
  finally { sql.close(); }
  assert.equal(witness(db, receipt).localOnly, false);
});

test('a body modified without changing state or part index is not an intact local import', t => {
  const db = database(t);
  const receipt = importBundleBytes(input, db);
  assert.equal(witness(db, receipt).localOnly, true);
  const sql = new DatabaseSync(db);
  try { sql.prepare("UPDATE outbox SET body='{}' WHERE part=0").run(); }
  finally { sql.close(); }
  assert.equal(witness(db, receipt).localOnly, false);
  assert.equal(importBundleBytes(input, db).disposition, 'duplicate');
  assert.equal(witness(db, receipt).localOnly, false);
});

test('an old revision without a manifest is inspectable but not newly attested on retry', t => {
  const db = database(t);
  const receipt = importBundleBytes(input, db);
  const sql = new DatabaseSync(db);
  try { sql.exec('DROP TABLE local_import_manifest'); }
  finally { sql.close(); }
  assert.equal(witness(db, receipt).localOnly, false);
  assert.equal(importBundleBytes(input, db).disposition, 'duplicate');
  assert.equal(witness(db, receipt).localOnly, false);
});

test('projection failure rolls back revision, outbox and completeness manifest together', t => {
  const db = database(t);
  const store = new ImportStore(db);
  const summary = { identity: { namespace: 'synthetic', value: 'rollback' }, semanticDigest: 'b'.repeat(64) };
  try { assert.throws(() => store.stage(summary, () => [undefined])); }
  finally { store.close(); }
  const sql = new DatabaseSync(db);
  try {
    for (const table of ['runs', 'revisions', 'outbox', 'local_import_manifest'])
      assert.equal(sql.prepare(`SELECT count(*) AS n FROM ${table}`).get().n, 0);
  } finally { sql.close(); }
});
