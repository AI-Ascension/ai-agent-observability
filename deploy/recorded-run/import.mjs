#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { readBundle } from './bundle.mjs';
import { ImportStore } from './store.mjs';
import { project, otlpBodies } from './projection.mjs';
import { collectorEndpoint, deliver } from './delivery.mjs';

export function importBundle(path, database) {
  // Complete validation and projection precede any database creation or writes.
  const summary = project(readBundle(path));
  const store = new ImportStore(database);
  try { return { ...store.stage(summary, otlpBodies), counts: summary.counts,
    evidence: summary.evidence, contractSchemaDigest: summary.contractSchemaDigest, wireVersion: summary.wireVersion }; }
  finally { store.close(); }
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
