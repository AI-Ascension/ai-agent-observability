#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { readBundle, validateBundle } from './bundle.mjs';
export { BundleInputError } from './bundle.mjs';
import { ImportStore } from './store.mjs';
import { project, otlpBodies } from './projection.mjs';
import { collectorEndpoint, deliver } from './delivery.mjs';

// Additive owner error type: distinguish failure after validation from a rejected
// bundle without changing the existing CLI diagnostic message contract.
export class ImportPersistenceError extends Error {
  constructor(cause) {
    super(cause instanceof Error ? cause.message : 'recorded_import_failed', { cause });
    this.name = 'ImportPersistenceError';
    this.code = 'recorded_import_persistence_failed';
  }
}

export function importBundle(path, database) {
  return stageValidated(readBundle(path), database);
}

// The matrix hands the owner the exact already-pinned bytes; no second path read.
export function importBundleBytes(bytes, database) {
  return stageValidated(validateBundle(bytes), database);
}

function stageValidated(bundle, database) {
  // Complete validation and projection precede any database creation or writes.
  const summary = project(bundle);
  try {
    const store = new ImportStore(database);
    try { return { ...store.stage(summary, otlpBodies), counts: summary.counts,
      evidence: summary.evidence, contractSchemaDigest: summary.contractSchemaDigest, wireVersion: summary.wireVersion }; }
    finally { store.close(); }
  } catch (error) { throw new ImportPersistenceError(error); }
}

export async function main(args) {
  const [command, ...rest] = args;
  if (command === 'import' && (rest.length === 2 || (rest.length === 4 && rest[2] === '--collector'))) {
    const [bundle, database, , target] = rest;
    if (rest.length === 4) collectorEndpoint(target);
    const result = importBundle(bundle, database);
    if (rest.length === 4) {
      const store = new ImportStore(database);
      try { Object.assign(result, await deliver(store, result.runId, result.semanticDigest, target)); }
      finally { store.close(); }
    } else result.delivery = 'local_only';
    return result;
  }
  if (command === 'inspect' && rest.length === 2 && /^[a-f0-9]{64}$/.test(rest[1])) {
    const store = new ImportStore(rest[0], { readOnly: true });
    try { return { revisions: store.inspect(rest[1]) }; } finally { store.close(); }
  }
  throw new Error('usage_import_bundle_db_or_inspect_db_run_key');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then(result => console.log(JSON.stringify(result))).catch(error => {
    // Do not echo filesystem paths, network bodies, imported strings or stack traces.
    console.error(JSON.stringify({ ok: false, code: /^[a-z][a-z0-9_]{0,100}$/.test(error.message)
      ? error.message : 'recorded_import_failed' }));
    process.exitCode = 1;
  });
}
