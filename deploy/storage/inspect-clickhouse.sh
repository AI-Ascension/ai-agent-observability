#!/usr/bin/env bash
# Read-only, scoped administrator diagnostic. Does not print environments or data.
set -euo pipefail
[[ $# == 0 ]] || { echo 'Usage: inspect-clickhouse.sh' >&2; exit 64; }
[[ $EUID == 0 ]] || { echo 'Requires normal host administrator access.' >&2; exit 77; }
readonly container=ai-agent-observability-laminar-clickhouse
command -v podman >/dev/null
command -v jq >/dev/null
# Only the allowlisted fields below leave the raw inspect pipe.
podman inspect "$container" | jq '[.[] | {
  Id, Image, ImageName, Created,
  state: {status: .State.Status, pid: .State.Pid, health: .State.Health.Status},
  user: .Config.User,
  restart: .HostConfig.RestartPolicy,
  read_only: .HostConfig.ReadonlyRootfs,
  logging: .HostConfig.LogConfig,
  mounts: [.Mounts[] | {Type, Name, Source, Destination, RW}],
  graph: .GraphDriver
}]'
podman exec "$container" sh -eu -c '
  id
  for path in /var/lib/clickhouse /var/lib/clickhouse/tmp /var/log/clickhouse-server; do
    stat -c "%a %u %g %n" "$path" || true
    df -P "$path" || true
    df -Pi "$path" || true
  done
  for key in path tmp_path user_files_path format_schema_path logger.log logger.errorlog logger.console logger.use_syslog; do
    printf "%s=" "$key"
    clickhouse extract-from-config --config-file /etc/clickhouse-server/config.xml --key "$key" --try
  done
'
podman exec "$container" sh -eu -c '
  # Bounded metadata listing only; no data/log contents or credentials.
  ls -ld /var/log/clickhouse-server /var/log/clickhouse-server/clickhouse-server.log \
    /var/log/clickhouse-server/clickhouse-server.err.log 2>/dev/null || true
  ps -eo uid,gid,comm | head -30
'
# Scope the host allocation inventory to this container, do not traverse live data.
while IFS= read -r path; do
  findmnt -T "$path" -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID
  df -B1 "$path"
done < <(podman inspect "$container" | jq -r '.[0].Mounts[].Source | select(startswith("/"))')
printf '%s\n' 'Data size, active-table inventory, exact image digest, logger rename permissions and IO rates still require owner review.'
