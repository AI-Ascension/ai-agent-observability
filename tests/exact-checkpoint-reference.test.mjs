// SPDX-License-Identifier: MIT
// Consumer conformance for the shared public checkpoint reference.
// Run with: node --test tests/exact-checkpoint-reference.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const root = new URL('../contract/exact-checkpoint-reference-v1/', import.meta.url);
const read = (path) => readFileSync(new URL(path, root));
const json = (path) => JSON.parse(read(path).toString('utf8'));
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

const ALLOWED = ['schema', 'reference_version', 'handle', 'occurrence', 'boundary_kind', 'boundary_phase', 'assurance', 'restore_verified'];
const ASSURANCE = ['public_observation_only', 'capture_only', 'restore_supported', 'restore_verified', 'continuation_certified'];

function admit(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return 'not_object';
  const keys = Object.keys(value);
  if (keys.some((key) => !ALLOWED.includes(key))) return 'unexpected_member';
  if (keys.length !== ALLOWED.length) return 'missing_member';
  if (value.schema !== 'ascension.exact_checkpoint_reference.v1') return 'unsupported_version';
  if (value.reference_version !== 'exact-checkpoint-reference-v1') return 'unsupported_version';
  if (typeof value.handle !== 'string' || !/^ckpt-h1:[0-9a-f]{64}$/.test(value.handle)) return 'invalid_handle';
  if (typeof value.occurrence !== 'string' || !/^[A-Za-z0-9_.:-]{1,256}$/.test(value.occurrence)) return 'invalid_occurrence';
  for (const label of [value.boundary_kind, value.boundary_phase]) {
    if (typeof label !== 'string' || label.length < 1 || label.length > 256 || label.includes('\0')) return 'invalid_boundary';
  }
  if (!ASSURANCE.includes(value.assurance)) return 'invalid_assurance';
  const claimsRestore = value.assurance === 'restore_verified' || value.assurance === 'continuation_certified';
  if (value.restore_verified !== claimsRestore) return 'invalid_restore_flag';
  return null;
}

for (const line of read('SHA256SUMS').toString().trim().split('\n')) {
  const [expected, path] = line.split(/\s+/);
  test(`contract checksum: ${path}`, () => assert.equal(digest(read(path)), expected));
}

test('the envelope is closed and defines no digest member', () => {
  const schema = json('schema.json');
  assert.equal(schema.additionalProperties, false);
  const names = Object.keys(schema.properties);
  assert.deepEqual(names.sort(), [...ALLOWED].sort());
  assert.ok(names.every((name) => !name.includes('digest')));
  assert.equal(schema.properties.assurance.enum.length, 5);
});

test('the golden reference is admitted and privileged or future ones are not', () => {
  assert.equal(admit(json('golden/reference.json')), null);
  assert.equal(admit(json('golden/invalid-privileged.json')), 'unexpected_member');
  assert.equal(admit(json('golden/unsupported-version.json')), 'unsupported_version');

  const overclaim = json('golden/reference.json');
  overclaim.assurance = 'capture_only';
  assert.equal(admit(overclaim), 'invalid_restore_flag');

  const weakHandle = json('golden/reference.json');
  weakHandle.handle = 'ckpt-h1:short';
  assert.equal(admit(weakHandle), 'invalid_handle');

  const missing = json('golden/reference.json');
  delete missing.occurrence;
  assert.equal(admit(missing), 'missing_member');
});
