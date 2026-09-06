#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# Repository-relative paths also work when the Compose CLI runs on Windows.
test_root="$(mktemp -d deploy/.env.validation.XXXXXX)"
trap 'rm -r -- "$test_root"' EXIT
settings=(BIND_ADDRESS MLFLOW_PORT RUSTFS_API_PORT RUSTFS_CONSOLE_PORT
  LAMINAR_HTTP_PORT LAMINAR_GRPC_PORT LAMINAR_REALTIME_PORT LAMINAR_FRONTEND_PORT
  QUICKWIT_HTTP_PORT QUICKWIT_OTLP_PORT OTEL_GRPC_PORT OTEL_HTTP_PORT
  OTEL_HEALTH_PORT OTEL_METRICS_PORT OTEL_STORAGE_METRICS_PORT)
for setting in "${settings[@]}"; do
  unset "$setting"
done
for setting in "${settings[@]}"; do
  for mode in blank missing; do
    if [[ $mode == blank ]]; then
      sed "s/^$setting=.*/$setting=/" deploy/.env.example >"$test_root/input"
    else
      sed "/^$setting=/d" deploy/.env.example >"$test_root/input"
    fi
    if docker compose --env-file "$test_root/input" -f deploy/compose.yaml config --quiet \
      >"$test_root/output" 2>&1; then
      printf 'Compose accepted %s setting %s\n' "$mode" "$setting" >&2
      exit 1
    fi
    grep -Fq "$setting" "$test_root/output"
  done
done
printf '%s\n' 'Compose rejects blank and missing host binding settings.'
