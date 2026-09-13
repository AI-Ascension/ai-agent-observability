#!/usr/bin/env bash
# Disposable runtime evidence only. It never targets a configured deployment.
set -euo pipefail

engine=${CONTAINER_ENGINE:-docker}
compose=("$engine" compose)
command -v "$engine" >/dev/null
"${compose[@]}" version >/dev/null

root=$(cd "$(dirname "$0")/.." && pwd)
project="aao-ci-${GITHUB_RUN_ID:-local}-$$"
work=$(mktemp -d)
logs="$work/diagnostics"
mkdir -p "$logs"
cleanup() {
  status=$?
  "${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" ps >"$logs/ps.txt" 2>&1 || true
  "${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" logs --no-color >"$logs/compose.log" 2>&1 || true
  # Diagnose a quiet but unhealthy Collector without exporting its environment
  # or credentials. The helper image is already used by this disposable stack.
  collector_id=$("${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" ps -q otel-collector) || collector_id=
  if [[ -n "$collector_id" ]]; then
    "$engine" inspect --format '{{json .State.Health}}' "$collector_id" >"$logs/collector-health.json" 2>&1 || true
    timeout 15s "$engine" run --rm --pull never --read-only --cap-drop ALL \
      --name "$project-health-diagnostic" \
      --network "container:$collector_id" docker.io/library/alpine:3.22.1 \
      sh -c 'printf "GET /status HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" | nc -w 5 127.0.0.1 13133' \
      >"$logs/collector-status.http" 2>&1 || true
    "$engine" rm -f "$project-health-diagnostic" >/dev/null 2>&1 || true
  fi
  # Do not use down -v or prune: only this project's containers/network stop.
  "${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" down --remove-orphans >"$logs/cleanup.log" 2>&1 || cleanup_failed=1
  tar -C "$work" -czf "$root/otlp-runtime-diagnostics.tar.gz" diagnostics 2>/dev/null || true
  rm -rf "$work"
  [[ ${cleanup_failed:-0} == 0 ]] || exit 1
  exit "$status"
}
trap cleanup EXIT

cp "$root/deploy/.env.example" "$work/.env"
# Replace all example-only secrets with valid, per-run synthetic values. This
# file is private to the disposable stack and is never copied into diagnostics.
node - "$work/.env" <<'NODE'
const fs = require('node:fs'), crypto = require('node:crypto');
const file = process.argv[2], value = () => crypto.randomBytes(32).toString('hex');
const env = Object.fromEntries(fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean)
  .filter(line => !line.startsWith('#')).map(line => { const i=line.indexOf('='); return [line.slice(0,i), line.slice(i+1)]; }));
const password = value(), access = crypto.randomBytes(24).toString('hex'), projectKey = crypto.randomBytes(48).toString('base64url');
Object.assign(env, {
  BIND_ADDRESS: '127.0.0.1', MLFLOW_POSTGRES_PASSWORD: password,
  MLFLOW_BACKEND_STORE_URI: `postgresql+psycopg2://mlflow:${password}@mlflow-postgres:5432/mlflow`,
  AWS_ACCESS_KEY_ID: access, AWS_SECRET_ACCESS_KEY: value(), NEXTAUTH_SECRET: value(),
  POSTGRES_PASSWORD: value(), RABBITMQ_DEFAULT_PASS: value(), CLICKHOUSE_PASSWORD: value(),
  CLICKHOUSE_RO_PASSWORD: value(), SHARED_SECRET_TOKEN: value(), AEAD_SECRET_KEY: value(),
  SLACK_ENCRYPTION_KEY: value(), LAMINAR_PROJECT_API_KEY: projectKey,
  OPENAI_API_KEY: '', LLM_API_KEY: '', LLM_BASE_URL: '', LLM_MODEL_SMALL: '', LLM_MODEL_MEDIUM: '', LLM_MODEL_LARGE: '',
  LAMINAR_TELEMETRY_DISABLED: 'true'
});
fs.writeFileSync(file, Object.entries(env).map(([key, item]) => `${key}=${item}`).join('\n') + '\n', {mode: 0o600});
NODE
# Render first, then make every mutable identity private. The checked-in model
# has fixed names/external network and is never passed to up/exec/down/logs.
"${compose[@]}" --env-file "$work/.env" -f "$root/deploy/compose.yaml" config --format json >"$work/rendered.json"
node - "$project" "$work/rendered.json" "$work/isolated.json" "${OTLP_SMOKE_MODE:-success}" <<'NODE'
const fs=require('node:fs'); const [project,input,output,mode]=process.argv.slice(2);
const model=JSON.parse(fs.readFileSync(input)); model.name=project;
for (const [name, service] of Object.entries(model.services ?? {})) {
  service.container_name=`${project}-${name}`;
  if (service.image?.startsWith('localhost/')) service.image=`${project}-${name}:ci`;
  // Only the two queried endpoints receive ephemeral loopback host ports.
  service.ports=(service.ports ?? []).flatMap((port) => {
    const target=Number(port.target);
    return (name === 'otel-collector' && target === 4318) || (name === 'mlflow' && target === 5000)
      ? [{...port, host_ip:'127.0.0.1', published:'0'}] : [];
  });
}
for (const [name, volume] of Object.entries(model.volumes ?? {})) { volume.name=`${project}-${name}`; volume.external=false; }
for (const [name, network] of Object.entries(model.networks ?? {})) { network.name=`${project}-${name}`; network.external=false; }
if (mode === 'startup-failure') {
  const collector=model.services?.['otel-collector'];
  if (!collector) throw new Error('collector missing from rendered model');
  collector.command=['/bin/sh', '-ec', 'exit 42'];
}
fs.writeFileSync(output, JSON.stringify(model));
NODE
"${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" config --quiet
if [[ ${OTLP_SMOKE_MODE:-success} == startup-failure ]]; then
  if "${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" up -d --build --wait --wait-timeout 300; then
    echo 'startup-failure negative case unexpectedly became healthy' >&2
    exit 1
  fi
  printf '%s\n' 'startup-failure negative case failed at the Collector as expected' >"$logs/result.txt"
  exit 0
fi
"${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" up -d --build --wait --wait-timeout 300

port_for() { "${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" port "$1" "$2" | tail -n 1; }
collector_port=$(port_for otel-collector 4318); mlflow_port=$(port_for mlflow 5000)
[[ "$collector_port" == 127.0.0.1:* && "$mlflow_port" == 127.0.0.1:* ]] || { echo 'ephemeral loopback ports unavailable' >&2; exit 1; }
collector="http://$collector_port/v1/traces"; mlflow="http://$mlflow_port"
# The test connects through an ephemeral published port but addresses MLflow's
# existing admitted authority. Keep the deployment's Host validation intact.
mlflow_request() {
  curl --max-time 5 --fail --silent --show-error -H 'Host: localhost:5000' "$@"
}
trace_hex=$(openssl rand -hex 16); span_hex=$(openssl rand -hex 8); trace_identity="ci-smoke-$trace_hex"
read -r start_ns end_ns < <(node -e 'const t=BigInt(Date.now())*1000000n; console.log(t.toString(),(t+1000000n).toString())')
payload=$(printf '{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"%s","spanId":"%s","name":"ci.synthetic.dual.backend","kind":1,"startTimeUnixNano":"%s","endTimeUnixNano":"%s","attributes":[{"key":"ci.trace_identity","value":{"stringValue":"%s"}}]}]}]}]}' "$trace_hex" "$span_hex" "$start_ns" "$end_ns" "$trace_identity")
if [[ ${OTLP_SMOKE_MODE:-success} == missing-ingestion ]]; then
  "${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" stop otel-collector
  if curl --max-time 3 --fail --silent --show-error -H 'content-type: application/json' --data "$payload" "$collector" >/dev/null; then
    echo 'missing-ingestion negative case unexpectedly accepted a valid trace' >&2
    exit 1
  fi
  sleep 3
  absent=$("${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" exec -T laminar-clickhouse clickhouse-client --query "SELECT count() FROM default.spans WHERE position(toString(attributes), '$trace_identity') > 0" 2>/dev/null || true)
  [[ "$absent" == 0 ]] || { echo 'missing-ingestion trace appeared in Laminar' >&2; exit 1; }
  printf '%s\n' 'missing-ingestion negative case failed at the Collector as expected' >"$logs/result.txt"
  exit 0
fi
curl --max-time 10 --fail --silent --show-error -H 'content-type: application/json' --data "$payload" "$collector" >"$logs/collector-receipt.json"
for _ in $(seq 1 30); do
  search=$(mlflow_request -H 'content-type: application/json' --data '{"locations":[{"mlflow_experiment":{"experiment_id":"0"}}],"max_results":100}' "$mlflow/api/3.0/mlflow/traces/search" || true)
  ids=$(printf '%s' "$search" | node -e 'let x="";process.stdin.on("data",d=>x+=d).on("end",()=>{try{const ids=[];const walk=v=>{if(v&&typeof v==="object"){if(typeof v.trace_id==="string")ids.push(v.trace_id);for(const q of Object.values(v))walk(q)}};walk(JSON.parse(x));console.log([...new Set(ids)].join("\n"))}catch{}})')
  mlflow_match=0
  while IFS= read -r trace_id; do
    [[ -n "$trace_id" ]] || continue
    detail=$(mlflow_request "$mlflow/api/3.0/mlflow/traces/get?trace_id=$trace_id" || true)
    grep -Fq "$trace_identity" <<<"$detail" && { mlflow_match=1; break; }
  done <<<"$ids"
  laminar=$("${compose[@]}" -p "$project" --env-file "$work/.env" -f "$work/isolated.json" exec -T laminar-clickhouse clickhouse-client --query "SELECT count() FROM default.spans WHERE position(toString(attributes), '$trace_identity') > 0" 2>/dev/null || true)
  if [[ "$mlflow_match" == 1 && "$laminar" =~ ^[1-9] ]]; then
    printf '%s\n' "dual backend trace identity verified: $trace_identity" >"$logs/result.txt"
    exit 0
  fi
  sleep 2
done
echo "dual-backend ingestion missing for synthetic trace identity" >&2
exit 1
