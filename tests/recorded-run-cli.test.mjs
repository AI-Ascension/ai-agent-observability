import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, existsSync, writeFileSync, readFileSync, readdirSync, statSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { main } from '../deploy/recorded-run/import.mjs';
import { ImportStore } from '../deploy/recorded-run/store.mjs';

const bundle = fileURLToPath(new URL('../contract/recorded-run-bundle-v1-candidate3/golden/legacy-failed.zip', import.meta.url));
const cli = fileURLToPath(new URL('../deploy/recorded-run/import.mjs', import.meta.url));

test('explicit empty collector rejects before database creation or import', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'recorded-cli-'));
  try {
    const path = join(dir, 'imports.sqlite');
    const result = spawnSync(process.execPath, [cli, 'import', bundle, path, '--collector', ''], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stderr), { ok: false, code: 'collector_endpoint_must_be_loopback' });
    assert.equal(result.stdout, ''); assert.equal(existsSync(path), false);
    const first = await main(['import', bundle, path]);
    assert.equal(first.delivery, 'local_only');
    const before = readFileSync(path);
    await assert.rejects(main(['import', bundle, path, '--collector', '']), /collector_endpoint_must_be_loopback/);
    assert.deepEqual(readFileSync(path), before);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('inspect requires existing regular database and never creates or repairs schema', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'recorded-inspect-'));
  try {
    const path = join(dir, 'missing.sqlite'), key = 'a'.repeat(64);
    const result = spawnSync(process.execPath, [cli, 'inspect', path, key], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stderr), { ok: false, code: 'database_not_found' });
    assert.equal(existsSync(path), false);
    await assert.rejects(main(['inspect', dir, key]), /database_not_regular/);
    for (const data of ['', 'not a database']) {
      writeFileSync(path, data);
      await assert.rejects(main(['inspect', path, key]), /database_invalid/);
      assert.equal(readFileSync(path, 'utf8'), data);
    }
    const link = join(dir, 'link.sqlite'); symlinkSync(path, link);
    await assert.rejects(main(['inspect', link, key]), /database_not_regular/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('read-only inspection returns existing revisions without modifying database or directory', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'recorded-inspect-'));
  try {
    const path = join(dir, 'imports.sqlite');
    const first = await main(['import', bundle, path]);
    const bytes = readFileSync(path), before = statSync(path), files = readdirSync(dir);
    const inspected = await main(['inspect', path, first.runId]);
    assert.equal(inspected.revisions.length, 1);
    assert.equal(inspected.revisions[0].semanticDigest, first.semanticDigest);
    assert.deepEqual(await main(['inspect', path, 'a'.repeat(64)]), { revisions: [] });
    const store = new ImportStore(path, { readOnly: true });
    try { assert.throws(() => store.db.exec('CREATE TABLE forbidden (id INTEGER)'), /readonly/i); }
    finally { store.close(); }
    assert.deepEqual(readFileSync(path), bytes);
    assert.equal(statSync(path).mtimeMs, before.mtimeMs);
    assert.deepEqual(readdirSync(dir), files);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
