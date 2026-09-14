#!/usr/bin/env node
// Bounded, read-only operator query path for gameplay telemetry acceptance.
//
// This is the repository-owned consumer for the operator key that
// `provision-query-readonly.sh` installs. It is deliberately separate from the
// Collector's ingest-only key: the upstream `/v1/sql/query` route uses the
// standard project validator, which returns a blank HTTP 404 for an
// `is_ingest_only=true` key. The operator path therefore never reuses the
// ingestion key and never sends it to the SQL route.
//
// Every value that is not a fixed literal is validated before use:
//   - deployment dotenv text is parsed as data, never evaluated as shell input;
//   - listener URLs must resolve to a loopback host;
//   - the operator key is read from a root-owned mode-0600 file, never argv;
//   - projected evidence contains only allowlisted correlation/outcome fields.
//
// No live service, credential, container engine, or network is touched by the
// repository test suite; tests inject a simulated transport.

import { lstatSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const MAX_RESULT_ROWS = 500;
export const MAX_TEXT_BYTES = 512;
// MLflow experiment ids are non-negative integers. Bound them so a hostile or
// accidental deployment value can neither be transmitted nor echoed into
// evidence. 19 digits is below the UInt64 range.
export const MAX_EXPERIMENT_ID_LENGTH = 19;

// The deployed ClickHouse table is resolved by the provisioning preflight to
// the `default.spans` MergeTree table; `default.spans_v0` is the read view.
export const LAMINAR_SPAN_TABLE = 'default.spans';
export const LAMINAR_SQL_COLUMNS = Object.freeze([
  'trace_id',
  'span_id',
  'name',
  'status',
  'start_time',
  'end_time',
  'attributes',
]);

// Every gameplay attribute is namespaced by the versioned STS2 contract, so the
// SQL is scoped to that namespace before ORDER BY/LIMIT. A co-located
// recorded-run import (`recorded.*`) therefore cannot crowd out the bounded
// window or fail the allowlist projection before gameplay rows are returned.
// The scope extracts top-level JSON keys and tests the `sts2.` namespace, so
// attribute values (which recorded imports may set to strings containing
// `sts2...`) cannot match. The upstream v0.2.3 `default.spans.attributes`
// column is a JSON `String`, so `JSONExtractKeys(attributes)` yields the
// top-level key array.
export const STS2_ATTRIBUTE_PREFIX = 'sts2.';

export function gameplayScopePredicate() {
  return `arrayExists(k -> startsWith(k, '${STS2_ATTRIBUTE_PREFIX}'), JSONExtractKeys(attributes))`;
}

// Exactly the gameplay attributes carried by the versioned STS2 contract
// (`docs/STS2_TELEMETRY_CONTRACT.md`). Nothing else is a queryable field.
export const STS2_ATTRIBUTE_ALLOWLIST = Object.freeze([
  'sts2.run_id',
  'sts2.episode_id',
  'sts2.trajectory_id',
  'sts2.trace_id',
  'sts2.instance_id',
  'sts2.session_id',
  'sts2.operation_id',
  'sts2.action_id',
  'sts2.generation',
  'sts2.model_execution_id',
  'sts2.status',
  'sts2.error_code',
  'sts2.effect_kind',
  'sts2.recovery',
  'sts2.id_encoding',
  'sts2.export_status',
]);

export const MLFLOW_TRACE_FIELDS = Object.freeze(['trace_id', 'state']);
export const MLFLOW_TRACE_SEARCH_PATH = '/api/3.0/mlflow/traces/search';
export const LAMINAR_SQL_QUERY_PATH = '/v1/sql/query';
export const LOOPBACK_HOSTS = Object.freeze(new Set(['127.0.0.1', 'localhost', '[::1]', '::1']));

export function fail(code) {
  throw new Error(code);
}

export function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

export function assertBoundedText(value, code, maximum = MAX_TEXT_BYTES) {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > maximum || /[\u0000-\u001f\u007f]/.test(value)) {
    fail(code);
  }
  return value;
}

// An experiment id is a bounded non-negative integer string. The CLI flag and
// the deployment `MLFLOW_EXPERIMENT_ID` both pass through here so an arbitrary
// dotenv value can never reach the MLflow request or the evidence object.
export function assertExperimentId(value) {
  if (typeof value !== 'string' || !/^[0-9]+$/.test(value) || value.length > MAX_EXPERIMENT_ID_LENGTH) {
    fail('mlflow_experiment_id_invalid');
  }
  return value;
}

// Parse a dotenv document as literal data. Values are never expanded, split,
// or executed; a hostile value such as `KEY=$(touch /tmp/pwned)` stays the
// exact string `$(touch /tmp/pwned)`.
export function parseDotenv(text) {
  if (typeof text !== 'string') fail('dotenv_text_required');
  const settings = new Map();
  for (const rawLine of text.split(/\r?\n/)) {
    let line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.slice(7).trimStart();
    const separator = line.indexOf('=');
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) fail('dotenv_key_invalid');
    let value = line.slice(separator + 1).trim();
    if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value[value.length - 1] === value[0]) {
      value = value.slice(1, -1);
      if (/[\r\n]/.test(value)) fail('dotenv_value_multiline');
    }
    settings.set(key, value);
  }
  return settings;
}

export function requireSetting(settings, name) {
  const value = settings.get(name);
  if (value === undefined || value === '') fail(`dotenv_missing:${name}`);
  return value;
}

// A deployment listener URL is admitted only when it names a loopback host. An
// all-interface bind, a hostname, a userinfo component, or a path is refused so
// the operator path can never be retargeted beyond the local host.
export function assertLoopbackUrl(raw, label) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail(`${label}_not_a_url`);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') fail(`${label}_scheme_forbidden`);
  if (url.username || url.password) fail(`${label}_userinfo_forbidden`);
  if (!LOOPBACK_HOSTS.has(url.hostname)) fail(`${label}_must_be_loopback`);
  return url;
}

export function laminarQueryUrl(baseUrl) {
  const url = assertLoopbackUrl(baseUrl, 'laminar');
  url.pathname = LAMINAR_SQL_QUERY_PATH;
  url.search = '';
  url.hash = '';
  return url;
}

export function mlflowSearchUrl(baseUrl) {
  const url = assertLoopbackUrl(baseUrl, 'mlflow');
  url.pathname = MLFLOW_TRACE_SEARCH_PATH;
  url.search = '';
  url.hash = '';
  return url;
}

// MLflow validates the full Host header against `--allowed-hosts`. The
// deployment admits the internal authority `localhost:5000` and the published
// loopback authority, so only those are sent.
export function admittedMlflowHosts(baseUrl) {
  const url = assertLoopbackUrl(baseUrl, 'mlflow');
  const host = url.hostname === '[::1]' ? '::1' : url.hostname;
  const admitted = new Set(['localhost:5000', '127.0.0.1:5000', 'mlflow:5000', host]);
  if (url.port) admitted.add(`${host}:${url.port}`);
  return admitted;
}

export function buildLaminarSql(limit) {
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_RESULT_ROWS) fail('laminar_limit_invalid');
  const columns = LAMINAR_SQL_COLUMNS.join(', ');
  return `SELECT ${columns} FROM ${LAMINAR_SPAN_TABLE} WHERE ${gameplayScopePredicate()} ORDER BY start_time DESC LIMIT ${limit}`;
}

export function validateLaminarResponse(payload) {
  if (!isPlainObject(payload)) fail('laminar_response_not_object');
  const keys = Object.keys(payload);
  if (keys.length !== 1 || keys[0] !== 'data') fail('laminar_response_unexpected_shape');
  if (!Array.isArray(payload.data)) fail('laminar_response_data_not_array');
  if (payload.data.length > MAX_RESULT_ROWS) fail('laminar_response_too_many_rows');
  for (const row of payload.data) {
    if (!isPlainObject(row)) fail('laminar_response_row_not_object');
  }
  return payload.data;
}

function sanitizeAttributes(attributes) {
  let parsed = attributes;
  if (typeof attributes === 'string') {
    try {
      parsed = JSON.parse(attributes);
    } catch {
      fail('laminar_attributes_unparseable');
    }
  }
  if (!isPlainObject(parsed)) fail('laminar_attributes_not_object');
  const projected = {};
  for (const [key, value] of Object.entries(parsed)) {
    if (!STS2_ATTRIBUTE_ALLOWLIST.includes(key)) fail(`laminar_attribute_not_allowlisted:${key}`);
    if (typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean') {
      fail(`laminar_attribute_value_not_scalar:${key}`);
    }
    if (typeof value === 'string') assertBoundedText(value, `laminar_attribute_value_too_long:${key}`);
    projected[key] = value;
  }
  return projected;
}

// Reject any field outside the bounded allowlist rather than dropping it, so a
// contract drift or an unexpected projection fails closed instead of silently
// producing incomplete evidence.
export function projectLaminarRow(row) {
  for (const key of Object.keys(row)) {
    if (!LAMINAR_SQL_COLUMNS.includes(key)) fail(`laminar_row_unexpected_field:${key}`);
  }
  if (!('trace_id' in row)) fail('laminar_row_missing_trace_id');
  const projected = {};
  const traceId = assertBoundedText(row.trace_id, 'laminar_trace_id_invalid', 64);
  projected.trace_id = traceId;
  if ('span_id' in row) projected.span_id = assertBoundedText(row.span_id, 'laminar_span_id_invalid', 64);
  if ('name' in row) projected.name = assertBoundedText(row.name, 'laminar_name_invalid');
  if ('status' in row) projected.status = assertBoundedText(row.status, 'laminar_status_invalid', 64);
  if ('start_time' in row) projected.start_time = row.start_time;
  if ('end_time' in row) projected.end_time = row.end_time;
  if ('attributes' in row) projected.attributes = sanitizeAttributes(row.attributes);
  return projected;
}

export function projectLaminarRows(rows) {
  return rows.map(projectLaminarRow);
}

export function validateMlflowSearchResponse(payload, maxResults) {
  if (!isPlainObject(payload)) fail('mlflow_response_not_object');
  if (!Array.isArray(payload.traces)) fail('mlflow_response_missing_traces');
  if (payload.traces.length > maxResults) fail('mlflow_response_too_many_traces');
  return payload.traces;
}

export function projectMlflowTrace(trace) {
  if (!isPlainObject(trace)) fail('mlflow_trace_not_object');
  const info = isPlainObject(trace.trace_info) ? trace.trace_info : {};
  const traceId = trace.trace_id ?? info.trace_id;
  const projected = { trace_id: assertBoundedText(traceId, 'mlflow_trace_id_invalid', 64) };
  const state = info.state ?? trace.state;
  if (state !== undefined) projected.state = assertBoundedText(state, 'mlflow_trace_state_invalid', 64);
  return projected;
}

export function projectMlflowTraces(traces) {
  return traces.map(projectMlflowTrace);
}

export async function queryLaminar({ baseUrl, token, sql, transport = fetch }) {
  const url = laminarQueryUrl(baseUrl);
  if (typeof token !== 'string' || token.length === 0) fail('laminar_operator_token_required');
  const response = await transport(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify({ query: sql, parameters: {} }),
  });
  if (response.status === 404) fail('laminar_ingest_only_key_rejected');
  if (response.status === 401 || response.status === 403) fail('laminar_operator_key_rejected');
  if (!response.ok) fail('laminar_query_failed');
  return projectLaminarRows(validateLaminarResponse(await response.json()));
}

export async function queryMlflow({ baseUrl, hostHeader, experimentId, maxResults, transport = fetch }) {
  const url = mlflowSearchUrl(baseUrl);
  if (!Number.isInteger(maxResults) || maxResults < 1 || maxResults > MAX_RESULT_ROWS) fail('mlflow_max_results_invalid');
  const admitted = admittedMlflowHosts(baseUrl);
  const authority = hostHeader ?? 'localhost:5000';
  if (!admitted.has(authority)) fail('mlflow_host_header_not_admitted');
  const body = {
    locations: [{ mlflow_experiment: { experiment_id: String(experimentId) } }],
    max_results: maxResults,
  };
  const response = await transport(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', host: authority },
    body: JSON.stringify(body),
  });
  if (response.status === 401 || response.status === 403) fail('mlflow_query_rejected');
  if (!response.ok) fail('mlflow_query_failed');
  return projectMlflowTraces(validateMlflowSearchResponse(await response.json(), maxResults));
}

// A protected operator key is a regular, non-symlink file whose permission bits
// grant no group or other access. Only the keyline is returned; the path and
// the raw file are never echoed into evidence.
export function readOperatorToken(keyFile) {
  let stats;
  try {
    stats = lstatSync(keyFile);
  } catch {
    fail('operator_key_unavailable');
  }
  if (!stats.isFile() || stats.isSymbolicLink()) fail('operator_key_not_regular');
  if ((stats.mode & 0o077) !== 0) fail('operator_key_permissions_too_broad');
  const token = readFileSync(keyFile, 'utf8').trim();
  if (!/^[0-9a-fA-F]{64}$/.test(token)) fail('operator_key_format_invalid');
  return token;
}

export function usage() {
  return 'usage: operator-query.mjs --env-file ABS --key-file ABS [--experiment-id N] [--limit N]';
}

export function parseArgs(args) {
  const options = { limit: 100 };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[index + 1];
    if (flag === '--env-file' && value && value.startsWith('/')) {
      options.envFile = value;
    } else if (flag === '--key-file' && value && value.startsWith('/')) {
      options.keyFile = value;
    } else if (flag === '--experiment-id' && value && /^[0-9]+$/.test(value)) {
      options.experimentId = assertExperimentId(value);
    } else if (flag === '--limit' && value && /^[0-9]+$/.test(value)) {
      options.limit = Number(value);
    } else {
      fail('operator_query_usage');
    }
    index += 1;
  }
  if (!options.envFile || !options.keyFile) fail('operator_query_usage');
  if (!Number.isInteger(options.limit) || options.limit < 1 || options.limit > MAX_RESULT_ROWS) fail('laminar_limit_invalid');
  return options;
}

export async function main(args, environment = process.env, transport = fetch) {
  if (environment.OBSERVABILITY_OPERATOR_QUERY_APPROVED !== 'true') fail('operator_query_not_approved');
  const options = parseArgs(args);
  const envStats = lstatSync(options.envFile);
  if (!envStats.isFile() || envStats.isSymbolicLink()) fail('deployment_env_not_regular');
  if ((envStats.mode & 0o077) !== 0) fail('deployment_env_permissions_too_broad');
  const settings = parseDotenv(readFileSync(options.envFile, 'utf8'));
  const bindAddress = settings.get('BIND_ADDRESS') ?? '127.0.0.1';
  if (!LOOPBACK_HOSTS.has(bindAddress)) fail('bind_address_must_be_loopback');
  const laminarPort = requireSetting(settings, 'LAMINAR_HTTP_PORT');
  const mlflowPort = requireSetting(settings, 'MLFLOW_PORT');
  const experimentId = assertExperimentId(options.experimentId ?? requireSetting(settings, 'MLFLOW_EXPERIMENT_ID'));
  const token = readOperatorToken(options.keyFile);
  const laminar = await queryLaminar({
    baseUrl: `http://${bindAddress}:${laminarPort}`,
    token,
    sql: buildLaminarSql(options.limit),
    transport,
  });
  const mlflow = await queryMlflow({
    baseUrl: `http://${bindAddress}:${mlflowPort}`,
    experimentId,
    maxResults: options.limit,
    transport,
  });
  return {
    ok: true,
    query_path: 'operator',
    ingest_key_reused: false,
    laminar_loopback: true,
    mlflow_loopback: true,
    mlflow_host_admitted: true,
    operator_key_source: 'protected_file',
    limit: options.limit,
    laminar_row_count: laminar.length,
    laminar_rows: laminar,
    mlflow_trace_count: mlflow.length,
    mlflow_experiment_id: experimentId,
    mlflow_traces: mlflow,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2))
    .then((evidence) => console.log(JSON.stringify(evidence)))
    .catch((error) => {
      const code = /^[a-z][a-z0-9_:.-]{0,120}$/.test(error.message) ? error.message : 'operator_query_failed';
      console.error(JSON.stringify({ ok: false, code }));
      process.exitCode = 1;
    });
}
