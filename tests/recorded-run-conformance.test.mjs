import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { digest, ImportStore } from '../deploy/recorded-run/store.mjs';
import { validateBundle } from '../deploy/recorded-run/bundle.mjs';
import { project, otlpBodies } from '../deploy/recorded-run/projection.mjs';
const root = new URL('../contract/recorded-run-bundle-v1/', import.meta.url);
const inventory = readFileSync(new URL('SHA256SUMS', root));
const inventoryDigest = '41d760f8c41064c4e6b49a48dbe6e1a6c8f2a9958afbc50374986a54858fd598';
assert.equal(digest(inventory), inventoryDigest, 'entire candidate artifact pin');
for (const line of inventory.toString().trim().split('\n')) {
  const [expected, path] = line.split(/\s+/);
  assert.equal(digest(readFileSync(new URL(path, root))), expected, path);
}
const conformance = JSON.parse(readFileSync(new URL('conformance.json', root)));
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
