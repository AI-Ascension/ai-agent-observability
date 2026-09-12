#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
# shellcheck source=deploy/storage/lifecycle.sh
source "$repo_root/deploy/storage/lifecycle.sh"

# Real kernel locks: a second lifecycle cannot enter until the first releases.
storage_take_lock "$test_root/run" 0
status=0
bash -c 'source "$1"; storage_take_lock "$2" 0' _ \
  "$repo_root/deploy/storage/lifecycle.sh" "$test_root/run" || status=$?
[[ $status == 75 ]]
exec 9>&-
bash -c 'source "$1"; storage_take_lock "$2" 0' _ \
  "$repo_root/deploy/storage/lifecycle.sh" "$test_root/run"

# Failure to allocate persistent state still leaves a runtime latch and proceeds
# to ALL stops. A regular file at the state path reliably injects I/O failure.
touch "$test_root/unavailable-state"
mkdir "$test_root/bin"
cat >"$test_root/bin/podman" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == inspect ]]; then
  echo true
elif [[ $1 == stop ]]; then
  echo "${*: -1}" >>"$STOP_EVENTS"
  [[ ${*: -1} != ai-agent-observability-otel-collector ]]
else
  exit 1
fi
FIXTURE
chmod +x "$test_root/bin/podman"
export PATH="$test_root/bin:$PATH" STOP_EVENTS="$test_root/stops"
failed=0
storage_latch_stop "$test_root/unavailable-state" "$test_root/run" 2>/dev/null || failed=1
[[ $failed == 1 && -e "$test_root/run/stopped" ]]
status=0
storage_stop_containers || status=$?
[[ $status == 1 ]]
printf '%s\n' ai-agent-observability-otel-collector ai-agent-observability-laminar-app-server \
  ai-agent-observability-laminar-clickhouse >"$test_root/expected"
cmp "$test_root/expected" "$STOP_EVENTS"
storage_latch_stop "$test_root/state" "$test_root/run"
[[ -e "$test_root/state/stopped" ]]

# Real path traversal plus command fixtures for mount/owner metadata, without
# requiring privileged test mounts. Nested mounts and directory substitution fail.
mkdir -p "$test_root/data/clickhouse" "$test_root/logs/legacy-clickhouse"
printf 'data.mountpoint\t%s/data\ndiagnostic.mountpoint\t%s/logs\n' "$test_root" "$test_root" >"$test_root/storage.tsv"
cat >"$test_root/bin/stat" <<'FIXTURE'
#!/usr/bin/env bash
if [[ $2 == '%u %a' ]]; then echo '0 755'; else /usr/bin/stat "$@"; fi
FIXTURE
cat >"$test_root/bin/findmnt" <<'FIXTURE'
#!/usr/bin/env bash
if [[ ${NESTED_MOUNT:-0} == 1 ]]; then echo "${*: -1}"; else dirname -- "${*: -1}"; fi
FIXTURE
chmod +x "$test_root/bin/stat" "$test_root/bin/findmnt"
bash "$repo_root/deploy/storage/check-bind-paths.sh" "$test_root/storage.tsv"
if NESTED_MOUNT=1 bash "$repo_root/deploy/storage/check-bind-paths.sh" "$test_root/storage.tsv" 2>/dev/null; then exit 1; fi
mv "$test_root/data/clickhouse" "$test_root/data/actual"
if bash "$repo_root/deploy/storage/check-bind-paths.sh" "$test_root/storage.tsv" 2>/dev/null; then exit 1; fi
ln -s actual "$test_root/data/clickhouse"
if bash "$repo_root/deploy/storage/check-bind-paths.sh" "$test_root/storage.tsv" 2>/dev/null; then exit 1; fi
echo 'Lifecycle locking, latch I/O failure, stop ordering/retry, and bind-path admission passed.'
