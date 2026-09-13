#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
command -v docker >/dev/null || exit 77
command -v jq >/dev/null || exit 77
if env -u OBS_DATA_ROOT -u OBS_DIAGNOSTIC_ROOT docker compose \
  --env-file deploy/.env.example -f deploy/compose.yaml \
  -f deploy/compose.storage-isolation.yaml config --quiet >/dev/null 2>&1; then
  echo 'Isolation silently accepted missing mount paths.' >&2; exit 1
fi
OBS_DATA_ROOT=/srv/test-observability-data OBS_DIAGNOSTIC_ROOT=/srv/test-observability-logs \
  docker compose --env-file deploy/.env.example -f deploy/compose.yaml \
  -f deploy/compose.storage-isolation.yaml config --format json | jq -e '
    .services["laminar-clickhouse"] as $s |
    ($s.read_only == true) and ($s.restart == "no") and
    ($s.logging.driver == "k8s-file") and
    ($s.logging.options.path == "/srv/test-observability-logs/clickhouse.log") and
    ($s.logging.options["max-size"] == "50mb") and
    ([$s.volumes[] | select(.target == "/var/lib/clickhouse")] | length == 1) and
    ([$s.volumes[] | select(.target == "/var/lib/clickhouse")][0] |
      .type == "bind" and .source == "/srv/test-observability-data/clickhouse" and
      (.bind.create_host_path // false) == false) and
    ([$s.volumes[] | select(.target == "/var/log/clickhouse-server")][0] |
      .type == "bind" and .read_only == true and (.bind.create_host_path // false) == false) and
    ($s.ulimits | has("core")) and (($s.ulimits.core.hard // 0) == 0) and
    ([$s.tmpfs[] | select(startswith("/etc/clickhouse-server/users.d:"))] | length == 1)
  ' >/dev/null
echo 'Storage override requires explicit paths and preserves the bounded ClickHouse model (static only).'
