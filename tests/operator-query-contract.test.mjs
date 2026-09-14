import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { chmodSync, mkdtempSync, rmSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  LAMINAR_SQL_COLUMNS,
  MAX_RESULT_ROWS,
  STS2_ATTRIBUTE_ALLOWLIST,
  STS2_ATTRIBUTE_PREFIX,
  admittedMlflowHosts,
  assertLoopbackUrl,
  buildLaminarSql,
  gameplayScopePredicate,
  main,
  parseArgs,
  parseDotenv,
  projectLaminarRow,
  projectMlflowTrace,
  queryLaminar,
  queryMlflow,
  readOperatorToken,
  validateLaminarResponse,
  validateMlflowSearchResponse,
} from '../deploy/laminar/operator-query.mjs';
import { validateBundle } from '../deploy/recorded-run/bundle.mjs';
import { project, otlpBodies } from '../deploy/recorded-run/projection.mjs';
import { fixture, bundleFor } from './recorded-run-fixtures/build.mjs';

const OPERATOR_TOKEN = 'a'.repeat(64);
const INGEST_TOKEN = 'b'.repeat(64);
const TRACE_ID = 'c'.repeat(32);
const SPAN_ID = 'd'.repeat(16);

function response(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

// Build ClickHouse-shaped rows from the REAL recorded-run projection so the
// regression test exercises actual importer output, not a hand-written
// approximation. The importer emits `recorded.*` keys whose values contain
// `sts2.` text (for example `sts2.runtime.operation`), which is exactly why a
// substring scope is unsafe.
function recordedClickHouseRows() {
  const summary = project(validateBundle(bundleFor(fixture())));
  const spans = otlpBodies('a'.repeat(64), summary).flatMap(b => b.resourceSpans[0].scopeSpans[0].spans);
  return spans.map((s) => {
    const attrs = Object.fromEntries((s.attributes ?? []).map((a) => {
      const v = a.value ?? {};
      return [a.key, v.stringValue ?? v.intValue ?? v.boolValue ?? ''];
    }));
    return {
      trace_id: s.traceId, span_id: s.spanId, name: s.name, status: 'OK',
      start_time: '2026-02-01 00:00:00.000000000', end_time: '2026-02-01 00:00:01.000000000',
      attributes: JSON.stringify(attrs),
    };
  });
}

// Model the scope predicate actually present in the request: key-based
// (`JSONExtractKeys(attributes)` plus `startsWith(k, 'sts2.')`) or the old
// substring form (`position(toString(attributes), 'sts2.')`). Then apply
// `ORDER BY start_time DESC` and the trailing `LIMIT <n>`. A query with no
// scope returns null so the caller can fall back to the pre-fix behavior; this
// lets the regression tests distinguish the two scopes instead of assuming the
// good predicate is present.
function scopeRows(query, rows) {
  const keyScoped = query.includes('JSONExtractKeys(attributes)') && query.includes("startsWith(k, 'sts2.')");
  const substringScoped = query.includes("position(toString(attributes), 'sts2.')");
  if (!keyScoped && !substringScoped) return null;
  const limitMatch = /LIMIT ([0-9]+)/.exec(query);
  const limit = limitMatch ? Number.parseInt(limitMatch[1], 10) : rows.length;
  const filtered = rows.filter((row) => {
    const serialized = typeof row.attributes === 'string' ? row.attributes : JSON.stringify(row.attributes);
    if (keyScoped) {
      const parsed = typeof row.attributes === 'string' ? JSON.parse(row.attributes) : row.attributes;
      return Object.keys(parsed).some((key) => key.startsWith(STS2_ATTRIBUTE_PREFIX));
    }
    return serialized.includes(STS2_ATTRIBUTE_PREFIX);
  });
  return filtered
    .sort((a, b) => (a.start_time < b.start_time ? 1 : a.start_time > b.start_time ? -1 : 0))
    .slice(0, limit);
}

// A deterministic, in-process simulation of the upstream route. It encodes the
// one behavior the repository cannot test live: the standard project validator
// returns a blank HTTP 404 for an ingest-only key on `/v1/sql/query`. The scope
// semantics come from `scopeRows`, so the tests exercise the request the
// production code actually emits.
function simulateLaminar({ rows, observed }) {
  return async (url, init) => {
    observed.push({ url: String(url), headers: init.headers, body: JSON.parse(init.body) });
    if (url.pathname !== '/v1/sql/query') return response(404, null);
    const token = String(init.headers.authorization ?? '').replace(/^Bearer /, '');
    if (token === INGEST_TOKEN) return response(404, null);
    if (token !== OPERATOR_TOKEN) return response(401, { error: 'unauthorized' });
    const scoped = scopeRows(String(init.body), rows);
    return response(200, { data: scoped ?? rows });
  };
}

function allowedRow(overrides = {}) {
  return {
    trace_id: TRACE_ID,
    span_id: SPAN_ID,
    name: 'sts2.run_started',
    status: 'OK',
    start_time: '2026-01-01 00:00:00.000000000',
    end_time: '2026-01-01 00:00:01.000000000',
    attributes: {
      'sts2.run_id': 'run-1',
      'sts2.episode_id': 'episode-1',
      'sts2.status': 'accepted',
      'sts2.id_encoding': 'digest',
    },
    ...overrides,
  };
}

test('dotenv values are parsed as literal data and never executed', () => {
  const parsed = parseDotenv([
    '# comment',
    'export BIND_ADDRESS=127.0.0.1',
    'SUBSTITUTION=$(touch /tmp/pwned)',
    'BACKTICK=`id`',
    'SEPARATOR=a;b|c',
    'QUOTED="$(rm -rf /)"',
    "SINGLE='still literal'",
    'EMPTY=',
  ].join('\n'));
  assert.equal(parsed.get('BIND_ADDRESS'), '127.0.0.1');
  assert.equal(parsed.get('SUBSTITUTION'), '$(touch /tmp/pwned)');
  assert.equal(parsed.get('BACKTICK'), '`id`');
  assert.equal(parsed.get('SEPARATOR'), 'a;b|c');
  assert.equal(parsed.get('QUOTED'), '$(rm -rf /)');
  assert.equal(parsed.get('SINGLE'), 'still literal');
  assert.equal(parsed.get('EMPTY'), '');
});

test('only loopback listener URLs are admitted', () => {
  for (const admitted of ['http://127.0.0.1:18000', 'http://localhost:18000', 'http://[::1]:18000']) {
    assert.equal(assertLoopbackUrl(admitted, 'laminar').hostname !== '', true);
  }
  for (const refused of [
    'http://0.0.0.0:18000',
    'http://192.0.2.1:18000',
    'http://example.com:18000',
    'http://user:pass@127.0.0.1:18000',
    'https://evil.example/redirect',
  ]) {
    assert.throws(() => assertLoopbackUrl(refused, 'laminar'), /laminar_(must_be_loopback|userinfo_forbidden|not_a_url)/);
  }
  // A base URL is an authority, not a path. The fixed query path replaces any
  // path silently, so a base URL carrying one is refused rather than accepted
  // with two meanings.
  assert.throws(() => assertLoopbackUrl('http://127.0.0.1:18000/evil', 'laminar'), /laminar_path_forbidden/);
  assert.throws(() => assertLoopbackUrl('http://127.0.0.1:18000/evil', 'mlflow'), /mlflow_path_forbidden/);
});

test('the SQL projection is bounded and allowlisted', () => {
  const sql = buildLaminarSql(25);
  // Pin the complete statement so a mutated or weakened predicate (for example
  // appending `OR 1`) cannot pass review while the behavioral model still
  // recognizes the scope.
  assert.equal(
    sql,
    'SELECT trace_id, span_id, name, status, start_time, end_time, attributes FROM default.spans '
      + "WHERE arrayExists(k -> startsWith(k, 'sts2.'), JSONExtractKeys(attributes)) "
      + 'ORDER BY start_time DESC LIMIT 25',
  );
  for (const column of LAMINAR_SQL_COLUMNS) assert.match(sql, new RegExp(`\\b${column}\\b`));
  assert.match(sql, /FROM default\.spans/);
  assert.ok(sql.includes(gameplayScopePredicate()));
  assert.match(sql, /arrayExists\(k -> startsWith\(k, 'sts2\.'\), JSONExtractKeys\(attributes\)\)/);
  assert.ok(sql.indexOf('WHERE') < sql.indexOf('ORDER BY'));
  assert.equal(/position\(/.test(sql), false);
  assert.match(sql, /LIMIT 25$/);
  for (const refused of [0, -1, MAX_RESULT_ROWS + 1, 1.5]) {
    assert.throws(() => buildLaminarSql(refused), /laminar_limit_invalid/);
  }
});

test('a simulated ingest-only key cannot query while the operator key can', async () => {
  const observed = [];
  const transport = simulateLaminar({ rows: [allowedRow()], observed });
  await assert.rejects(
    queryLaminar({ baseUrl: 'http://127.0.0.1:18000', token: INGEST_TOKEN, sql: buildLaminarSql(10), transport }),
    /laminar_ingest_only_key_rejected/,
  );
  const rows = await queryLaminar({
    baseUrl: 'http://127.0.0.1:18000',
    token: OPERATOR_TOKEN,
    sql: buildLaminarSql(10),
    transport,
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].trace_id, TRACE_ID);
  assert.equal(rows[0].attributes['sts2.run_id'], 'run-1');
  assert.equal(observed[0].url, 'http://127.0.0.1:18000/v1/sql/query');
  assert.match(observed[0].body.query, /LIMIT 10$/);
});

test('the gameplay scope excludes real recorded-run spans before the row limit', async () => {
  const recorded = recordedClickHouseRows();
  const rows = [...recorded, allowedRow()];
  // Recorded rows are newer than the gameplay row, so any weaker scope that
  // fails to exclude them would let them fill the binding row limit first.
  assert.ok(recorded.every((row) => row.start_time > rows[rows.length - 1].start_time));
  // Documents why the substring predicate was unsafe: recorded-run imports
  // carry `sts2.` text inside attribute VALUES.
  assert.ok(recorded.some((row) => JSON.stringify(row.attributes).includes(STS2_ATTRIBUTE_PREFIX)));
  // Documents the key discriminator the fixed scope relies on.
  assert.ok(recorded.every((row) => {
    const parsed = typeof row.attributes === 'string' ? JSON.parse(row.attributes) : row.attributes;
    return Object.keys(parsed).every((key) => !key.startsWith(STS2_ATTRIBUTE_PREFIX));
  }));
  const observed = [];
  const transport = simulateLaminar({ rows, observed });
  const sql = buildLaminarSql(2);
  const projected = await queryLaminar({
    baseUrl: 'http://127.0.0.1:18000',
    token: OPERATOR_TOKEN,
    sql,
    transport,
  });
  assert.equal(projected.length, 1);
  assert.equal(projected[0].attributes['sts2.run_id'], 'run-1');
  assert.ok(projected.every((row) => Object.keys(row.attributes).every((key) => !key.startsWith('recorded.'))));
  assert.equal(observed[0].body.query.includes(gameplayScopePredicate()), true);
});

test('the old substring scope is proven unsafe against real recorded-run spans', async () => {
  // The same real recorded-run rows, queried with the pre-fix substring scope
  // and a binding limit, fill the window and abort the projection. This is the
  // regression the key-based scope fixes; it fails if the key predicate is
  // replaced by any value-insensitive substring test.
  const rows = [...recordedClickHouseRows(), allowedRow()];
  const legacySql = `SELECT ${LAMINAR_SQL_COLUMNS.join(', ')} FROM default.spans `
    + "WHERE position(toString(attributes), 'sts2.') > 0 ORDER BY start_time DESC LIMIT 2";
  await assert.rejects(
    queryLaminar({
      baseUrl: 'http://127.0.0.1:18000',
      token: OPERATOR_TOKEN,
      sql: legacySql,
      transport: simulateLaminar({ rows, observed: [] }),
    }),
    /laminar_attribute_not_allowlisted:recorded\./,
  );
});

test('the response shape and allowlist fail closed on unknown fields', () => {
  assert.equal(validateLaminarResponse({ data: [] }).length, 0);
  assert.throws(() => validateLaminarResponse({ data: [], extra: 1 }), /laminar_response_unexpected_shape/);
  assert.throws(() => validateLaminarResponse({ data: {} }), /laminar_response_data_not_array/);
  assert.throws(() => validateLaminarResponse({ rows: [] }), /laminar_response_unexpected_shape/);

  assert.throws(
    () => projectLaminarRow(allowedRow({ private_prompt: 'PRIVATE_PROMPT_SENTINEL' })),
    /laminar_row_unexpected_field:private_prompt/,
  );
  assert.throws(
    () => projectLaminarRow(allowedRow({ attributes: { 'sts2.private_prompt': 'PRIVATE_PROMPT_SENTINEL' } })),
    /laminar_attribute_not_allowlisted:sts2\.private_prompt/,
  );
  assert.throws(
    () => projectLaminarRow(allowedRow({ attributes: { 'random.attr': 'x' } })),
    /laminar_attribute_not_allowlisted:random\.attr/,
  );
  const projected = projectLaminarRow(allowedRow());
  assert.deepEqual(Object.keys(projected.attributes).sort(), ['sts2.episode_id', 'sts2.id_encoding', 'sts2.run_id', 'sts2.status'].sort());
  assert.equal(STS2_ATTRIBUTE_ALLOWLIST.includes('sts2.private_prompt'), false);
});

test('span timestamps are bounded scalars and fail closed on drift', () => {
  // Valid forms: a bounded string, a finite number, and a nullable end_time.
  assert.equal(projectLaminarRow(allowedRow()).start_time, '2026-01-01 00:00:00.000000000');
  assert.equal(projectLaminarRow(allowedRow({ start_time: 1767225600 })).start_time, 1767225600);
  assert.equal(projectLaminarRow(allowedRow({ end_time: null })).end_time, null);
  for (const bad of ['x'.repeat(10000), { secret: 'PRIVATE_PROMPT_SENTINEL' }, ['a'], NaN, Infinity, true]) {
    assert.throws(() => projectLaminarRow(allowedRow({ start_time: bad })), /laminar_start_time_invalid/);
    assert.throws(() => projectLaminarRow(allowedRow({ end_time: bad })), /laminar_end_time_invalid/);
  }
});

test('MLflow is queried through its effective, admitted loopback authority', async () => {
  const observed = [];
  const transport = async (url, init) => {
    observed.push({ url: String(url), authority: url.host, headers: init.headers, body: JSON.parse(init.body) });
    if (url.host !== '127.0.0.1:15000') return response(403, null);
    return response(200, { traces: [{ trace_id: TRACE_ID, trace_info: { state: 'OK' } }] });
  };
  assert.equal(admittedMlflowHosts('http://127.0.0.1:15000').has('127.0.0.1:15000'), true);
  const traces = await queryMlflow({
    baseUrl: 'http://127.0.0.1:15000',
    experimentId: '0',
    maxResults: 10,
    transport,
  });
  assert.deepEqual(traces, [{ trace_id: TRACE_ID, state: 'OK' }]);
  assert.equal(observed[0].url, 'http://127.0.0.1:15000/api/3.0/mlflow/traces/search');
  assert.equal(observed[0].authority, '127.0.0.1:15000');
  // The request no longer sets an explicit (and therefore ignored) Host header.
  assert.equal(observed[0].headers.host, undefined);
  assert.deepEqual(observed[0].body, { locations: [{ mlflow_experiment: { experiment_id: '0' } }], max_results: 10 });
  await assert.rejects(
    queryMlflow({ baseUrl: 'http://127.0.0.1:15000', hostHeader: 'evil.example:5000', experimentId: '0', maxResults: 10, transport }),
    /mlflow_host_header_not_admitted/,
  );
  await assert.rejects(
    queryMlflow({ baseUrl: 'http://127.0.0.1:15000', experimentId: 'PRIVATE_PROMPT_SENTINEL', maxResults: 10, transport }),
    /mlflow_experiment_id_invalid/,
  );
  await assert.rejects(
    queryMlflow({ baseUrl: 'http://127.0.0.1:15000', experimentId: '1'.repeat(20), maxResults: 10, transport }),
    /mlflow_experiment_id_invalid/,
  );
  assert.throws(() => validateMlflowSearchResponse({ traces: [{ trace_id: TRACE_ID }] }, 0), /mlflow_response_too_many_traces/);
  assert.throws(() => validateMlflowSearchResponse({ results: [] }, 10), /mlflow_response_missing_traces/);
  assert.deepEqual(projectMlflowTrace({ trace_info: { trace_id: TRACE_ID, state: 'OK' } }), { trace_id: TRACE_ID, state: 'OK' });
});

test('the real fetch transport sends the URL authority as the Host header', async () => {
  // The injected-transport tests cannot observe Node's forbidden-header
  // handling. This one binds a loopback server and pins the authority that the
  // production `fetch` actually sends, so a future switch back to an explicit
  // `host` header (which is ignored) is caught.
  const observedHosts = [];
  const server = http.createServer((request, res) => {
    observedHosts.push(request.headers.host);
    request.resume();
    request.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ traces: [] }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const { port } = server.address();
    const authority = `127.0.0.1:${port}`;
    await queryMlflow({ baseUrl: `http://${authority}`, experimentId: '0', maxResults: 5 });
    assert.deepEqual(observedHosts, [authority]);
    assert.equal(admittedMlflowHosts(`http://${authority}`).has(authority), true);
    // A direct request with a conflicting explicit Host is still governed by
    // fetch's forbidden-header handling: the server must see the URL authority,
    // not the requested value. This is the wire property the injected-transport
    // tests cannot observe.
    await fetch(`http://${authority}/probe`, { headers: { host: 'evil.example:5000' } });
    assert.deepEqual(observedHosts, [authority, authority]);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('the operator token is read from a protected file, never argv', () => {
  const dir = mkdtempSync(join(tmpdir(), 'operator-key-'));
  try {
    const keyFile = join(dir, 'laminar-query-key');
    writeFileSync(keyFile, `${OPERATOR_TOKEN}\n`, { mode: 0o600 });
    assert.equal(readOperatorToken(keyFile), OPERATOR_TOKEN);
    chmodSync(keyFile, 0o644);
    assert.throws(() => readOperatorToken(keyFile), /operator_key_permissions_too_broad/);
    chmodSync(keyFile, 0o600);
    writeFileSync(keyFile, 'not-a-key\n', { mode: 0o600 });
    assert.throws(() => readOperatorToken(keyFile), /operator_key_format_invalid/);
    const link = join(dir, 'laminar-query-key-link');
    symlinkSync(keyFile, link);
    assert.throws(() => readOperatorToken(link), /operator_key_not_regular/);
    assert.throws(() => readOperatorToken(join(dir, 'missing')), /operator_key_unavailable/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the operator path is loopback-only, approved, and secret-free in evidence', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'operator-evidence-'));
  try {
    const envFile = join(dir, 'deploy.env');
    const keyFile = join(dir, 'laminar-query-key');
    writeFileSync(envFile, [
      'BIND_ADDRESS=127.0.0.1',
      'LAMINAR_HTTP_PORT=18000',
      'MLFLOW_PORT=15000',
      'MLFLOW_EXPERIMENT_ID=0',
      'LAMINAR_PROJECT_API_KEY=should-never-appear',
    ].join('\n'), { mode: 0o600 });
    writeFileSync(keyFile, `${OPERATOR_TOKEN}\n`, { mode: 0o600 });
    const transport = simulateLaminar({ rows: [allowedRow()], observed: [] });
    const mlflowTransport = async () => response(200, { traces: [{ trace_id: TRACE_ID }] });
    const evidence = await main(
      ['--env-file', envFile, '--key-file', keyFile, '--limit', '5'],
      { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' },
      async (url, init) => (String(url).includes('/v1/sql/query') ? transport(url, init) : mlflowTransport(url, init)),
    );
    assert.equal(evidence.ingest_key_reused, false);
    assert.equal(evidence.laminar_loopback, true);
    assert.equal(evidence.mlflow_loopback, true);
    assert.equal(evidence.operator_key_source, 'protected_file');
    assert.equal(evidence.laminar_row_count, 1);
    assert.equal(evidence.mlflow_experiment_id, '0');
    const serialized = JSON.stringify(evidence);
    assert.equal(serialized.includes(OPERATOR_TOKEN), false);
    assert.equal(serialized.includes(INGEST_TOKEN), false);
    assert.equal(serialized.includes('should-never-appear'), false);

    await assert.rejects(
      main(['--env-file', envFile, '--key-file', keyFile], {}, async () => response(200, { data: [] })),
      /operator_query_not_approved/,
    );
    writeFileSync(envFile, 'BIND_ADDRESS=0.0.0.0\nLAMINAR_HTTP_PORT=18000\nMLFLOW_PORT=15000\n', { mode: 0o600 });
    await assert.rejects(
      main(['--env-file', envFile, '--key-file', keyFile], { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' }, async () => response(200, { data: [] })),
      /bind_address_must_be_loopback/,
    );
    chmodSync(envFile, 0o644);
    await assert.rejects(
      main(['--env-file', envFile, '--key-file', keyFile], { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' }, async () => response(200, { data: [] })),
      /deployment_env_permissions_too_broad/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the MLflow experiment defaults to MLFLOW_EXPERIMENT_ID unless overridden', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'operator-experiment-'));
  try {
    const envFile = join(dir, 'deploy.env');
    const keyFile = join(dir, 'laminar-query-key');
    writeFileSync(envFile, [
      'BIND_ADDRESS=127.0.0.1',
      'LAMINAR_HTTP_PORT=18000',
      'MLFLOW_PORT=15000',
      'MLFLOW_EXPERIMENT_ID=7',
    ].join('\n'), { mode: 0o600 });
    writeFileSync(keyFile, `${OPERATOR_TOKEN}\n`, { mode: 0o600 });
    const mlflowBodies = [];
    const laminarObserved = [];
    const laminarTransport = simulateLaminar({ rows: [allowedRow()], observed: laminarObserved });
    const transport = async (url, init) => {
      if (String(url).includes('/v1/sql/query')) return laminarTransport(url, init);
      mlflowBodies.push(JSON.parse(init.body));
      return response(200, { traces: [] });
    };
    const approved = { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' };
    const defaultEvidence = await main(['--env-file', envFile, '--key-file', keyFile], approved, transport);
    assert.equal(mlflowBodies[0].locations[0].mlflow_experiment.experiment_id, '7');
    assert.equal(defaultEvidence.mlflow_experiment_id, '7');
    const overrideEvidence = await main(
      ['--env-file', envFile, '--key-file', keyFile, '--experiment-id', '3'],
      approved,
      transport,
    );
    assert.equal(mlflowBodies[1].locations[0].mlflow_experiment.experiment_id, '3');
    assert.equal(overrideEvidence.mlflow_experiment_id, '3');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a deployment without MLFLOW_EXPERIMENT_ID fails closed unless overridden', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'operator-no-experiment-'));
  try {
    const envFile = join(dir, 'deploy.env');
    const keyFile = join(dir, 'laminar-query-key');
    writeFileSync(envFile, [
      'BIND_ADDRESS=127.0.0.1',
      'LAMINAR_HTTP_PORT=18000',
      'MLFLOW_PORT=15000',
    ].join('\n'), { mode: 0o600 });
    writeFileSync(keyFile, `${OPERATOR_TOKEN}\n`, { mode: 0o600 });
    await assert.rejects(
      main(
        ['--env-file', envFile, '--key-file', keyFile],
        { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' },
        async () => response(200, { data: [] }),
      ),
      /dotenv_missing:MLFLOW_EXPERIMENT_ID/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a non-numeric or oversized MLFLOW_EXPERIMENT_ID fails closed and never reaches a request', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'operator-bad-experiment-'));
  try {
    const envFile = join(dir, 'deploy.env');
    const keyFile = join(dir, 'laminar-query-key');
    writeFileSync(keyFile, `${OPERATOR_TOKEN}\n`, { mode: 0o600 });
    const calls = [];
    const transport = async (url) => { calls.push(String(url)); return response(200, { data: [], traces: [] }); };
    for (const bad of ['PRIVATE_PROMPT_SENTINEL', '1'.repeat(4096), '-1', '1.5', '0x10']) {
      writeFileSync(envFile, [
        'BIND_ADDRESS=127.0.0.1',
        'LAMINAR_HTTP_PORT=18000',
        'MLFLOW_PORT=15000',
        `MLFLOW_EXPERIMENT_ID=${bad}`,
      ].join('\n'), { mode: 0o600 });
      await assert.rejects(
        main(['--env-file', envFile, '--key-file', keyFile], { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' }, transport),
        /mlflow_experiment_id_invalid/,
      );
    }
    assert.deepEqual(calls, []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an invalid CLI --experiment-id fails with the documented code', () => {
  const base = ['--env-file', '/x', '--key-file', '/y'];
  assert.equal(parseArgs([...base, '--experiment-id', '7']).experimentId, '7');
  for (const bad of ['abc', '-1', '1.5', '0x10', '1'.repeat(20)]) {
    assert.throws(
      () => parseArgs([...base, '--experiment-id', bad]),
      /mlflow_experiment_id_invalid/,
    );
  }
  assert.throws(() => parseArgs([...base, '--experiment-id']), /operator_query_usage/);
  assert.throws(() => parseArgs(['--experiment-id']), /operator_query_usage/);
});

test('an invalid CLI experiment id fails before any transport call', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'operator-cli-bad-experiment-'));
  try {
    const envFile = join(dir, 'deploy.env');
    const keyFile = join(dir, 'laminar-query-key');
    writeFileSync(envFile, [
      'BIND_ADDRESS=127.0.0.1',
      'LAMINAR_HTTP_PORT=18000',
      'MLFLOW_PORT=15000',
      'MLFLOW_EXPERIMENT_ID=0',
    ].join('\n'), { mode: 0o600 });
    writeFileSync(keyFile, `${OPERATOR_TOKEN}\n`, { mode: 0o600 });
    const calls = [];
    const transport = async (url) => { calls.push(String(url)); return response(200, { data: [], traces: [] }); };
    await assert.rejects(
      main(
        ['--env-file', envFile, '--key-file', keyFile, '--experiment-id', 'abc'],
        { OBSERVABILITY_OPERATOR_QUERY_APPROVED: 'true' },
        transport,
      ),
      /mlflow_experiment_id_invalid/,
    );
    assert.deepEqual(calls, []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
