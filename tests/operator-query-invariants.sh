#!/usr/bin/env bash
set -euo pipefail

# Static, effect-free invariants for the bounded operator query path. The
# behavioral tests live in tests/operator-query.test.mjs; this gate proves the
# checked-in source keeps its loopback, data-parsing, and secret-hygiene
# properties even on a runner without Node.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/deploy/laminar/operator-query.mjs"
docs="$repo_root/docs/OPERATOR_QUERY.md"

[[ -f "$module" ]] || { printf '%s\n' 'operator query module is missing' >&2; exit 1; }
[[ -f "$docs" ]] || { printf '%s\n' 'operator query documentation is missing' >&2; exit 1; }

# The query path must never evaluate deployment text or shell out.
if grep -Eq '(^|[^[:alnum:]_.])(eval|exec|execSync|spawn|spawnSync|child_process|Function)[[:space:]]*\(' "$module"; then
  printf '%s\n' 'operator query module contains a command-execution primitive' >&2
  exit 1
fi
if grep -Eq '(source|\.)[[:space:]]+.*\.env|/bin/(sh|bash)|sh -c' "$module"; then
  printf '%s\n' 'operator query module shells out to deploy state' >&2
  exit 1
fi

for required in \
  "'/v1/sql/query'" \
  "'/api/3.0/mlflow/traces/search'" \
  'localhost:5000' \
  'laminar_ingest_only_key_rejected' \
  'laminar_attribute_not_allowlisted' \
  'laminar_row_unexpected_field' \
  'bind_address_must_be_loopback' \
  'operator_query_not_approved' \
  'operator_key_permissions_too_broad' \
  'OBSERVABILITY_OPERATOR_QUERY_APPROVED' \
  'ingest_key_reused: false' \
  'default.spans' \
  'position(toString(attributes)' \
  'MLFLOW_EXPERIMENT_ID' \
  'sts2.run_id' \
  'sts2.export_status'; do
  grep -Fq -- "$required" "$module"
done

if grep -Eq "\b[0-9a-fA-F]{64}\b" "$module"; then
  printf '%s\n' 'operator query module contains a hard-coded 64-character credential' >&2
  exit 1
fi

shopt -s nullglob
operator_query_tests=("$repo_root"/tests/operator-query-*.test.mjs)
if (( ${#operator_query_tests[@]} == 0 )); then
  printf '%s\n' 'no tests/operator-query-*.test.mjs matches the CI glob' >&2
  exit 1
fi
grep -Fq 'operator-query.mjs' "$repo_root/README.md"
grep -Fq 'operator-query.mjs' "$repo_root/docs/OPERATIONS.md"
grep -Fq 'tests/operator-query-*.test.mjs' "$repo_root/.github/workflows/ci.yml"
grep -Fq 'tests/operator-query-invariants.sh' "$repo_root/.github/workflows/ci.yml"

printf '%s\n' 'Operator query path is loopback-only, data-parsed, and secret-free (static invariants).'
