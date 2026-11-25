import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import * as owner from '../deploy/recorded-run/import.mjs';
import { ImportStore } from '../deploy/recorded-run/store.mjs';

const fixtures = new URL('../contract/recorded-run-bundle-v1-candidate3/', import.meta.url);
const good = fileURLToPath(new URL('golden/legacy-failed.zip', fixtures));
const bad = fileURLToPath(new URL('invalid/tampered-content.zip', fixtures));
function scratch(t) {
  const path = mkdtempSync(join(tmpdir(), 'recorded-owner-boundary-'));
  t.after(() => rmSync(path, { recursive: true, force: true }));
  return path;
}
const inputFailure = error => error.code === 'recorded_bundle_input_failed';
const persistenceFailure = error => error.code === 'recorded_import_persistence_failed';

test('byte import and path import use identical local transactions and duplicate receipts', t => {
  const path = scratch(t), a = join(path, 'path.db'), b = join(path, 'bytes.db');
  const first = owner.importBundle(good, a);
  assert.deepEqual(owner.importBundleBytes(readFileSync(good), b), first);
  assert.equal(owner.importBundleBytes(readFileSync(good), b).disposition, 'duplicate');
  const left = new ImportStore(a, { readOnly: true }), right = new ImportStore(b, { readOnly: true });
  try { assert.deepEqual(left.inspect(first.runId), right.inspect(first.runId)); }
  finally { left.close(); right.close(); }
});

test('invalid bundle bytes remain semantic rejection before any database creation', t => {
  const path = scratch(t), db = join(path, 'invalid.db');
  for (const run of [() => owner.importBundle(bad, db),
    () => owner.importBundleBytes(readFileSync(bad), db)]) {
    assert.throws(run, error => !inputFailure(error) && !persistenceFailure(error)
      && error instanceof Error && !(error instanceof TypeError));
    assert.equal(existsSync(db), false);
  }
});

test('missing, directory and linked inputs fail acquisition rather than semantic validation', t => {
  const path = scratch(t), db = join(path, 'unused.db'), link = join(path, 'linked.zip');
  symlinkSync(good, link);
  for (const input of [join(path, 'missing.zip'), path, link]) {
    assert.throws(() => owner.importBundle(input, db), inputFailure);
    assert.equal(existsSync(db), false);
  }
});

test('FIFO acquisition cannot block before regular-file proof', t => {
  const path = scratch(t), fifo = join(path, 'fifo'), db = join(path, 'unused.db');
  assert.equal(spawnSync('mkfifo', [fifo]).status, 0);
  const module = new URL('../deploy/recorded-run/import.mjs', import.meta.url).href;
  const run = spawnSync(process.execPath, ['--input-type=module', '-e',
    'const m=await import(process.argv[1]);try{m.importBundle(process.argv[2],process.argv[3]);process.exitCode=2}catch(e){console.log(e.code)}',
    module, fifo, db], { encoding: 'utf8', timeout: 3000 });
  assert.equal(run.error, undefined);
  assert.equal(run.status, 0);
  assert.equal(run.stdout.trim(), 'recorded_bundle_input_failed');
  assert.equal(existsSync(db), false);
});

test('valid input with unavailable storage reports a persistence failure', t => {
  const db = join(scratch(t), 'absent', 'run.db');
  assert.throws(() => owner.importBundle(good, db), persistenceFailure);
  assert.throws(() => owner.importBundleBytes(readFileSync(good), db), persistenceFailure);
  assert.equal(existsSync(db), false);
});

test('outbox insertion failure rolls back run, revision and delivery rows before retry', t => {
  const db = join(scratch(t), 'fault.db');
  new ImportStore(db).close();
  const sql = new DatabaseSync(db);
  try {
    sql.exec("CREATE TRIGGER fail_insert BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT,'synthetic_fault'); END;");
    assert.throws(() => owner.importBundleBytes(readFileSync(good), db), persistenceFailure);
    for (const table of ['runs', 'revisions', 'outbox']) {
      assert.equal(sql.prepare(`SELECT count(*) AS n FROM ${table}`).get().n, 0);
    }
    sql.exec('DROP TRIGGER fail_insert');
    assert.equal(owner.importBundleBytes(readFileSync(good), db).disposition, 'imported');
    assert.equal(owner.importBundleBytes(readFileSync(good), db).disposition, 'duplicate');
    assert.equal(sql.prepare('SELECT count(*) AS n FROM revisions').get().n, 1);
    assert.equal(sql.prepare("SELECT count(*) AS n FROM outbox WHERE endpoint IS NOT NULL OR state != 'pending'").get().n, 0);
    assert.ok(sql.prepare('SELECT count(*) AS n FROM outbox').get().n > 0);
  } finally { sql.close(); }
});
