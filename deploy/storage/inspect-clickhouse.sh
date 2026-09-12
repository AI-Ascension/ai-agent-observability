#!/usr/bin/env bash
# Read-only, scoped administrator diagnostic. Does not print environments or data.
set -euo pipefail
[[ $# == 0 ]] || { echo 'Usage: inspect-clickhouse.sh' >&2; exit 64; }
[[ $EUID == 0 ]] || { echo 'Requires normal host administrator access.' >&2; exit 77; }
readonly container=ai-agent-observability-laminar-clickhouse
command -v podman >/dev/null
command -v jq >/dev/null
# Only the allowlisted fields below leave the raw inspect pipe.
timeout 20s podman inspect "$container" | jq '[.[] | {
  Id, Image, ImageName, Created,
  state: {status: .State.Status, pid: .State.Pid, health: .State.Health.Status},
  user: .Config.User,
  restart: .HostConfig.RestartPolicy,
  read_only: .HostConfig.ReadonlyRootfs,
  logging: .HostConfig.LogConfig,
  mounts: [.Mounts[] | {Type, Name, Source, Destination, RW}],
  graph: .GraphDriver
}]'
image_id=$(timeout 20s podman inspect --format '{{.Image}}' "$container")
timeout 20s podman image inspect "$image_id" | jq '[.[] | {Id, RepoDigests, Architecture, Os, Created}]'
systemctl show ai-agent-observability.service \
  -p FragmentPath -p DropInPaths -p ActiveState -p SubState -p User -p WorkingDirectory
timeout 30s podman exec "$container" sh -eu -c '
  id
  clickhouse --version
  for path in /var/lib/clickhouse /var/lib/clickhouse/tmp /var/log/clickhouse-server; do
    stat -c "%a %u %g %n" "$path" || true
    df -P "$path" || true
    df -Pi "$path" || true
  done
  for key in path tmp_path user_files_path format_schema_path logger.log logger.errorlog logger.console logger.use_syslog; do
    printf "%s=" "$key"
    clickhouse extract-from-config --config-file /etc/clickhouse-server/config.xml --key "$key" --try
  done
  if [ -f /var/lib/clickhouse/preprocessed_configs/config.xml ]; then
    for key in logger.log logger.errorlog logger.console logger.use_syslog; do
      printf "preprocessed.%s=" "$key"
      clickhouse extract-from-config --config-file /var/lib/clickhouse/preprocessed_configs/config.xml --key "$key" --try
    done
  fi
'
timeout 30s podman exec "$container" sh -eu -c '
  # Bounded metadata listing only; no data/log contents or credentials.
  ls -ld /var/log/clickhouse-server /var/log/clickhouse-server/clickhouse-server.log \
    /var/log/clickhouse-server/clickhouse-server.err.log 2>/dev/null || true
  ps -eo uid,gid,comm | head -30
'
# Query only aggregate storage metadata. Credentials stay inside the container;
# never dump environments, sample application rows or export query-log contents.
# This is a point-in-time footprint, not retained bytes/day or a backup.
timeout 30s podman exec "$container" sh -eu -c '
  : "${CLICKHOUSE_USER:?Container account is required}"
  : "${CLICKHOUSE_PASSWORD:?Container credential is required}"
  clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --max_execution_time 10 --query "SELECT database, table, active, count() AS parts, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk, sum(data_compressed_bytes) AS compressed_bytes FROM system.parts GROUP BY database, table, active ORDER BY bytes_on_disk DESC LIMIT 1000 FORMAT JSONEachRow"
  clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --max_execution_time 10 --query "SELECT name, path, total_space, free_space, unreserved_space, keep_free_space FROM system.disks LIMIT 1000 FORMAT JSONEachRow"
'
# Scope the host allocation inventory to this container, do not traverse live data.
while IFS= read -r path; do
  findmnt -T "$path" -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID
  df -B1 "$path"
done < <(timeout 20s podman inspect "$container" | jq -r '.[0].Mounts[].Source | select(startswith("/"))')
printf '%s\n' 'Private metadata report: do not commit raw output. Namespace rename permissions, retained growth, merge peaks and complete host log routing still require operator verification.'
