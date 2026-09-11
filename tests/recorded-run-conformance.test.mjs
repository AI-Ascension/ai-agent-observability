import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { digest, ImportStore } from '../deploy/recorded-run/store.mjs';
import { validateBundle } from '../deploy/recorded-run/bundle.mjs';
import { project, otlpBodies } from '../deploy/recorded-run/projection.mjs';
import { SCHEMA_DIGEST, WIRE_VERSION } from '../deploy/recorded-run/validation.mjs';
const root = new URL('../contract/recorded-run-bundle-v1-candidate3/', import.meta.url);
const inventory = readFileSync(new URL('SHA256SUMS', root));
const inventoryDigest = '580c1cf3be4bb3e4eb37b9acd9166808b7386b0eb84286cc0798a0d88e35bb35';
assert.equal(digest(inventory), inventoryDigest, 'entire candidate artifact pin');
for (const line of inventory.toString().trim().split('\n')) {
  const [expected, path] = line.split(/\s+/);
  assert.equal(digest(readFileSync(new URL(path, root))), expected, path);
}
const conformance = JSON.parse(readFileSync(new URL('conformance.json', root)));
const manifest = JSON.parse(readFileSync(new URL('manifest.json', root)));
assert.equal(conformance.schema_sha256, SCHEMA_DIGEST);
assert.equal(manifest.schema_sha256, SCHEMA_DIGEST);
assert.equal(conformance.version, WIRE_VERSION);
assert.equal(manifest.version, WIRE_VERSION);
assert.equal(conformance.profile, manifest.artifact);
assert.equal(conformance.cases.filter(c => c.valid).length, 8);
assert.equal(conformance.cases.filter(c => !c.valid).length, 25);
for (const vector of conformance.cases) test(`protocol candidate: ${vector.path}`, () => {
  const bytes = readFileSync(new URL(vector.path, root));
  assert.equal(digest(bytes), vector.sha256);
  if (!vector.valid) return assert.throws(() => validateBundle(bytes));
  const bundle = validateBundle(bytes), store = new ImportStore(':memory:');
  try {
    const summary = project(bundle);
    const first = store.stage(summary, otlpBodies);
    assert.equal(store.stage(summary, otlpBodies).disposition, 'duplicate');
    assert.equal(store.inspect(first.runId).length, 1);
  } finally { store.close(); }
});
