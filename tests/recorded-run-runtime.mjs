// Optional real local backend proof. Prerequisites and installation: docs/RECORDED_RUN.md.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { main } from '../deploy/recorded-run/import.mjs';
import { SCHEMA_DIGEST, WIRE_VERSION, INVENTORY_DIGEST } from '../deploy/recorded-run/validation.mjs';
import { digest } from '../deploy/recorded-run/store.mjs';
import { readBundle } from '../deploy/recorded-run/bundle.mjs';
import { bundleFor } from './recorded-run-fixtures/build.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const local = join(root, '.local-test'); mkdirSync(local, { recursive: true });
const dir = mkdtempSync(join(local, 'runtime-'));
const python = join(local, 'mlflow-env/bin/python'), collector = join(local, 'otelcol-contrib');
const env = { PATH: '/usr/local/bin:/usr/bin:/bin', LANG: 'C.UTF-8',
  MLFLOW_DISABLE_TELEMETRY: 'true', MLFLOW_DISABLE_AGENT_HINT: '1',
  MLFLOW_SERVER_ENABLE_JOB_EXECUTION: 'false',
  MLFLOW_TRACKING_URI: `sqlite:///${join(dir, 'mlflow.sqlite')}` };
async function freePort() {
  const server = createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = server.address().port; await new Promise(resolve => server.close(resolve)); return port;
}
const mlflowPort = await freePort(), collectorPort = await freePort();
const tracking = `http://127.0.0.1:${mlflowPort}`, intake = `http://127.0.0.1:${collectorPort}/v1/traces`;
const processes = new Set();
function launch(binary, args, name) {
  const child = spawn(binary, args, { cwd: dir, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  for (const stream of [child.stdout, child.stderr]) stream.on('data', b => { log = (log + b).slice(-262144); });
  child.once('error', e => { log += e.code; });
  child.once('exit', () => writeFileSync(join(dir, name + '.log'), log, { mode: 0o600 }));
  processes.add(child); return child;
}
async function stop(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch { return; }
  await Promise.race([once(child, 'exit'), delay(10000)]);
  if (child.exitCode === null && child.signalCode === null) {
    process.kill(-child.pid, 'SIGKILL'); await once(child, 'exit');
  }
}
async function until(fn, label) {
  for (let n = 0; n < 120; n++) {
    try { const value = await fn(); if (value) return value; } catch { /* bounded startup/ingest polling */ }
    await delay(250);
  }
  throw new Error(label);
}
const launchMlflow = () => launch(python, ['-m', 'mlflow', 'server', '--host', '127.0.0.1',
  '--port', String(mlflowPort), '--workers', '1', '--backend-store-uri', env.MLFLOW_TRACKING_URI,
  '--default-artifact-root', join(dir, 'artifacts')], 'mlflow');
const ready = () => until(async () => (await fetch(tracking + '/health', { signal: AbortSignal.timeout(1000) })).ok, 'mlflow_startup_failed');
async function traces() {
  const response = await fetch(tracking + '/api/3.0/mlflow/traces/search', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
      locations: [{ mlflow_experiment: { experiment_id: '0' } }], max_results: 100 }),
    signal: AbortSignal.timeout(3000) });
  assert.equal(response.status, 200);
  return (await response.json()).traces ?? [];
}
async function getTrace(id) {
  const response = await fetch(tracking + '/api/3.0/mlflow/traces/get?trace_id=' + encodeURIComponent(id),
    { signal: AbortSignal.timeout(3000) });
  assert.equal(response.status, 200);
  return (await response.json()).trace;
}
const config = `receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:${collectorPort}
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
    spike_limit_mib: 64
  batch:
    send_batch_size: 128
    timeout: 1s
exporters:
  otlp_http/mlflow:
    endpoint: ${tracking}
    headers:
      x-mlflow-experiment-id: '0'
    compression: gzip
    timeout: 10s
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 2
      queue_size: 1024
service:
  telemetry:
    logs:
      level: warn
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp_http/mlflow]
`;
writeFileSync(join(dir, 'collector.yaml'), config, { mode: 0o600 });
const source = process.argv[2] ? resolve(process.argv[2]) : join(root, 'contract/recorded-run-bundle-v1/golden/legacy-failed.zip');
let mlflow, otel;
try {
  mlflow = launchMlflow(); await ready();
  otel = launch(collector, ['--config', join(dir, 'collector.yaml')], 'collector');
  await until(async () => { const r = await fetch(intake, { signal: AbortSignal.timeout(1000) }); return r.status === 405; }, 'collector_startup_failed');
  const database = join(dir, 'imports.sqlite');
  const first = await main(['import', source, database, '--collector', intake]);
  assert.equal(first.delivery, 'collector_acknowledged');
  const rows = await until(async () => { const r = await traces(); return r.length ? r : false; }, 'mlflow_ingestion_failed');
  assert.equal(rows.length, 1);
  const traceId = rows[0].trace_id;
  const trace = await getTrace(traceId);
  writeFileSync(join(dir, 'trace.json'), JSON.stringify(trace), { mode: 0o600 });
  const serialized = JSON.stringify(trace);
  assert(serialized.includes(first.semanticDigest));
  assert(serialized.includes('recorded.snapshot'));
  assert(serialized.includes('episode_failed'));
  assert(serialized.includes('seed-readiness.accounting.model-execution'));
  assert(serialized.includes('seed-readiness.trajectory.model-execution'));
  const attr = (span, key) => span.attributes.find(a => a.key === key)?.value;
  const accountingSpan = trace.spans.find(s => s.name === 'recorded.accounting');
  const modelSpan = trace.spans.find(s => attr(s, 'recorded.identities.model_execution.namespace')?.string_value
    === 'seed-readiness.trajectory.model-execution');
  assert.notDeepEqual(attr(modelSpan, 'recorded.identities.model_execution.value'),
    attr(accountingSpan, 'recorded.identities.model_execution.value'));
  const admitted = readBundle(source);
  for (const [key, usage] of Object.entries(admitted.accounting[0].payload.value.usage)) {
    assert.equal(attr(accountingSpan, `recorded.payload.usage.${key}.value_status`).string_value, usage.value_status);
    if (usage.value === null) assert.equal(attr(accountingSpan, `recorded.payload.usage.${key}.value`), undefined);
    else assert.equal(attr(accountingSpan, `recorded.payload.usage.${key}.value`).string_value, usage.value);
  }
  const actionSpans = trace.spans.filter(s => s.name === 'recorded.action_outcome');
  assert.equal(actionSpans.length, 2);
  assert(actionSpans.every(s => attr(s, 'recorded.evidence.action').string_value === 'unknown'));
  for (const marker of ['PRIVATE_PROMPT_SENTINEL', 'BEARER_TOKEN_SENTINEL', 'C:\\Users\\private'])
    assert(!serialized.includes(marker));
  const retry = await main(['import', source, database, '--collector', intake]);
  assert.equal(retry.disposition, 'duplicate'); assert.equal(retry.acknowledgedParts, 0);
  assert.equal((await traces()).length, 1);
  let revisionsVerified = 1, expectedTrace = trace;
  if (!process.argv[2]) {
    const f = { manifest: admitted.manifest, report: admitted.omissions,
      events: admitted.events, accounting: admitted.accounting };
    f.manifest.adapter.version = 'synthetic-revision-2';
    const revisionFile = join(dir, 'revision.zip'); writeFileSync(revisionFile, bundleFor(f));
    const revision = await main(['import', revisionFile, database, '--collector', intake]);
    assert.equal(revision.disposition, 'revision_added'); assert.equal(revision.runId, first.runId);
    expectedTrace = await until(async () => {
      const value = await getTrace(traceId);
      return value.spans.filter(s => s.name === 'recorded.snapshot').length === 2 ? value : false;
    }, 'mlflow_revision_failed');
    assert.equal((await traces()).length, 1);
    assert.equal(expectedTrace.spans.length, trace.spans.length * 2);
    assert(JSON.stringify(expectedTrace).includes(first.semanticDigest));
    assert(JSON.stringify(expectedTrace).includes(revision.semanticDigest));
    revisionsVerified = 2;
  }
  await stop(otel); await stop(mlflow);
  mlflow = launchMlflow(); await ready();
  const afterRestart = await traces(); assert.equal(afterRestart.length, 1);
  assert.equal(afterRestart[0].trace_id, traceId);
  assert.deepEqual(await getTrace(traceId), expectedTrace);
  const evidence = { result: 'passed', fixtureProvenance: process.argv[2] ? 'supplied_bundle' : 'synthetic',
    mlflowVersion: '3.16.0', collectorVersion: '0.160.0', schemaDigest: SCHEMA_DIGEST,
    wireVersion: WIRE_VERSION, inventoryDigest: INVENTORY_DIGEST, revisionsVerified,
    storedSpans: expectedTrace.spans.length, accountingVerified: true,
    artifactSha256: digest(readFileSync(source)), semanticDigest: first.semanticDigest,
    logicalRunKey: first.runId, traceId, tracesBefore: 1, tracesAfterRetry: 1,
    tracesAfterRestart: 1, counts: first.counts, evidence: first.evidence,
    mlflowTelemetryDisabled: true, laminar: 'unverified', topology: 'loopback-collector-to-mlflow' };
  writeFileSync(join(dir, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n');
  console.log(JSON.stringify(evidence));
  console.log('Local test evidence: ' + dir);
} finally { for (const child of processes) await stop(child); }
