#!/usr/bin/env bash
# Pure parser fixtures: no Docker, network, credentials or deployment data.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT
jq -n '
  ["mlflow-postgres", "mlflow-storage", "mlflow-create-bucket", "mlflow",
   "laminar-postgres", "laminar-clickhouse", "laminar-rabbitmq",
   "laminar-quickwit", "laminar-app-server", "laminar-frontend",
   "laminar-bootstrap", "otel-collector"] as $services |
  [["mlflow-postgres", "mlflow-postgres-data", "/var/lib/postgresql/data"],
   ["mlflow-storage", "mlflow-storage-data", "/data"],
   ["laminar-postgres", "laminar-postgres-data", "/var/lib/postgresql/data"],
   ["laminar-clickhouse", "laminar-clickhouse-data", "/var/lib/clickhouse"],
   ["laminar-clickhouse", "laminar-clickhouse-logs", "/var/log/clickhouse-server"],
   ["laminar-quickwit", "laminar-quickwit-data", "/quickwit/qwdata"]] as $mounts |
  {services: ($services | map({key:.,value:{}}) | from_entries),
   networks:{default:{external:true}},volumes:{}} |
  reduce $mounts[] as $mount (.;
    .services[$mount[0]].volumes += [{type:"volume",source:$mount[1],target:$mount[2]}] |
    .volumes[$mount[1]] = {}) |
  .services.mlflow.ports = [{host_ip:"127.0.0.1",published:"15000",target:5000}] |
  .services["laminar-app-server"].environment.LAMINAR_TELEMETRY_DISABLED = "true"
' > "$test_root/valid.json"
jq -e -f "$repo_root/tests/compose-policy.jq" "$test_root/valid.json" >/dev/null
mutations=(
  'del(.services.mlflow.ports[0].host_ip)'
  '.services.mlflow.ports[0].host_ip = "0.0.0.0"'
  '.services.mlflow.ports[0].host_ip = "::"'
  '.services.mlflow.ports[0].published = "65536"'
  '.services.mlflow.ports = []'
  'del(.services["mlflow-postgres"])'
  '.services.mlflow.network_mode = "host"'
  '.services.mlflow.privileged = true'
  '.services.mlflow.volumes = [{type:"bind",source:"synthetic",target:"/data"}]'
  'del(.services["mlflow-postgres"].volumes)'
  '.services["mlflow-postgres"].volumes[0].read_only = true'
  'del(.volumes["mlflow-postgres-data"])'
  '.networks.default.external = false'
  '.services["laminar-app-server"].environment.LAMINAR_TELEMETRY_DISABLED = "false"'
  '{}'
)
for mutation in "${mutations[@]}"; do
  jq "$mutation" "$test_root/valid.json" > "$test_root/invalid.json"
  if jq -e -f "$repo_root/tests/compose-policy.jq" "$test_root/invalid.json" > "$test_root/result" 2>&1; then
    printf 'Accepted invalid model mutation: %s\n' "$mutation" >&2; exit 1
  fi
done
printf '{broken' > "$test_root/invalid.json"
if jq -e -f "$repo_root/tests/compose-policy.jq" "$test_root/invalid.json" > "$test_root/result" 2>&1; then
  echo 'Accepted malformed JSON' >&2; exit 1
fi
# Internal container binding is not a host publish and must remain valid.
jq '.services.mlflow.command = ["--host", "0.0.0.0"]' "$test_root/valid.json" |
  jq -e -f "$repo_root/tests/compose-policy.jq" >/dev/null
printf 'Structured Compose policy: 2 positive, %s negative cases passed.\n' "$(( ${#mutations[@]} + 1 ))"
