#!/usr/bin/env bash
set -euo pipefail

# Provision the separate Laminar operator query key and ClickHouse read-only
# account without putting a secret in process arguments, shell history, or
# evidence. All live reads and backups complete before the first persistent
# mutation. A failed mutation compensates the other systems from those
# backups. This helper is root-only and never restarts Compose.

# ---------------------------------------------------------------------------
# Module layout (issue #47 behavior-preserving split)
#
#   provision-query/lib-common.sh      fatal errors + dotenv value parsing
#   provision-query/lib-cleanup.sh     staged-file / container-path cleanup trap
#   provision-query/lib-clickhouse.sh  ClickHouse query helper + guarded drop
#   provision-query/lib-postgres.sh    pgpass-backed psql file runner
#   provision-query/lib-reconcile.sh   commit classification + exact row restore
#   provision-query/lib-rollback.sh    ordered cross-system compensation
#   provision-query/phase-preflight.sh live reads before any backup
#   provision-query/phase-backup.sh    exact restorable state + credentials
#   provision-query/phase-mutate.sh    persistent writes under the rollback trap
#
# The libraries only define functions. The phase modules contain top-level
# statements and therefore execute in order when sourced, in one shell, so the
# original `set -euo pipefail` error, trap and global-variable semantics are
# preserved. The entry point below stays a thin coordinator.
# ---------------------------------------------------------------------------
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
provision_query_dir="$script_dir/provision-query"
for provision_query_module in \
  lib-common.sh lib-cleanup.sh lib-clickhouse.sh lib-postgres.sh lib-reconcile.sh \
  lib-rollback.sh phase-preflight.sh phase-backup.sh phase-mutate.sh; do
  # shellcheck source=/dev/null
  source "$provision_query_dir/$provision_query_module"
done
