import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const cli = fileURLToPath(new URL('../deploy/recorded-run/import.mjs', import.meta.url));
const bundle = fileURLToPath(new URL('../contract/recorded-run-bundle-v1-candidate3/golden/legacy-failed.zip', import.meta.url));

async function fixture(t, respond) {
  const dir = mkdtempSync(join(tmpdir(), 'recorded-run-process-'));
  const db = join(dir, 'owner.sqlite3');
  const requests = [];
  const children = new Map();
  const server = createServer(async (req, res) => {
    try {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      requests.push({ method: req.method, path: req.url, body: Buffer.concat(chunks).toString('utf8') });
      await respond(req, res, requests.length);
    } catch { res.destroy(); }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const endpoint = `http://127.0.0.1:${server.address().port}/v1/traces`;
  t.after(async () => {
    const closing = [...children.entries()];
    for (const [child] of closing) child.kill('SIGKILL');
    server.closeAllConnections();
    await Promise.allSettled(closing.map(([, completed]) => completed));
    await new Promise(resolve => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  });
  function start(args) {
    const child = spawn(process.execPath, ['--no-warnings', cli, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
    const completed = once(child, 'close').then(([code, signal]) => {
      children.delete(child);
      return { code, signal, stdout, stderr };
    });
    children.set(child, completed);
    return { child, completed };
  }
  const send = () => start(['import', bundle, db, '--collector', endpoint]);
  const local = () => start(['import', bundle, db]).completed;
  const rows = () => {
    const reader = new DatabaseSync(db, { readOnly: true });
    try { return reader.prepare('SELECT part,state,body,endpoint FROM outbox ORDER BY part').all(); }
    finally { reader.close(); }
  };
  return { endpoint, requests, send, local, rows };
}
function acknowledge(res) {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end('{}');
}
function reconciliation(result) {
  assert.equal(result.code, 1, result.stderr);
  assert.deepEqual(JSON.parse(result.stderr), { ok: false, code: 'delivery_reconciliation_required' });
  assert.equal(result.stdout, '');
}

test('real CLI and loopback HTTP: staged payload survives restart; acknowledgement is not repeated', { timeout: 15000 }, async t => {
  const f = await fixture(t, (_req, res) => acknowledge(res));
  const staged = await f.local();
  assert.equal(staged.code, 0, staged.stderr);
  const receipt = JSON.parse(staged.stdout);
  assert.equal(receipt.delivery, 'local_only');
  const before = f.rows();
  assert.ok(before.length > 0);
  assert.ok(before.every(row => row.state === 'pending' && row.endpoint === null));
  const first = await f.send().completed;
  assert.equal(first.code, 0, first.stderr);
  assert.equal(JSON.parse(first.stdout).delivery, 'collector_acknowledged');
  assert.equal(JSON.parse(first.stdout).backendPersistence, 'unverified');
  assert.deepEqual(f.requests.map(r => r.body), before.map(r => r.body));
  assert.ok(f.requests.every(r => r.method === 'POST' && r.path === '/v1/traces'));
  assert.ok(f.rows().every(row => row.state === 'acknowledged' && row.endpoint === f.endpoint));
  const replay = await f.send().completed;
  assert.equal(replay.code, 0, replay.stderr);
  assert.equal(JSON.parse(replay.stdout).delivery, 'already_acknowledged');
  assert.equal(f.requests.length, before.length);
});

test('real CLI: process loss after HTTP request arrival retains sending state and refuses restart resend', { timeout: 15000 }, async t => {
  let received;
  const arrived = new Promise(resolve => { received = resolve; });
  const f = await fixture(t, (_req, _res) => { received(); });
  const first = f.send();
  await Promise.race([arrived, first.completed.then(result => { throw Error(`premature exit ${result.stderr}`); })]);
  assert.equal(f.rows()[0].state, 'sending');
  first.child.kill('SIGKILL');
  const killed = await first.completed;
  assert.ok(killed.signal === 'SIGKILL' || (process.platform === 'win32' && killed.code !== 0));
  const retry = await f.send().completed;
  reconciliation(retry);
  assert.equal(f.requests.length, 1);
  assert.equal(f.rows()[0].state, 'sending');
});

test('real CLI: concurrent caller cannot resend a claimed part', { timeout: 15000 }, async t => {
  let received, release;
  const arrived = new Promise(resolve => { received = resolve; });
  const proceed = new Promise(resolve => { release = resolve; });
  const f = await fixture(t, async (_req, res) => { received(); await proceed; acknowledge(res); });
  const first = f.send();
  await Promise.race([arrived, first.completed.then(result => { throw Error(`premature exit ${result.stderr}`); })]);
  try {
    reconciliation(await f.send().completed);
    assert.equal(f.requests.length, 1);
    assert.equal(f.rows()[0].state, 'sending');
  } finally { release(); }
  const result = await first.completed;
  assert.equal(result.code, 0, result.stderr);
  assert.equal(f.rows()[0].state, 'acknowledged');
});

test('real CLI: collector disconnect after request body arrival persists unknown; no retry delivery', { timeout: 15000 }, async t => {
  const f = await fixture(t, (_req, res) => res.destroy());
  reconciliation(await f.send().completed);
  assert.equal(f.rows()[0].state, 'unknown');
  reconciliation(await f.send().completed);
  assert.equal(f.requests.length, 1);
});

test('real CLI: HTTP partial rejection is not an acknowledgement', { timeout: 15000 }, async t => {
  const f = await fixture(t, (_req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ partialSuccess: { rejectedSpans: '1', errorMessage: 'synthetic rejection' } }));
  });
  reconciliation(await f.send().completed);
  assert.equal(f.rows()[0].state, 'unknown');
  reconciliation(await f.send().completed);
  assert.equal(f.requests.length, 1);
});
