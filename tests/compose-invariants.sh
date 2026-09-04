#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

compose_output="$(docker compose --env-file deploy/.env.example -f deploy/compose.yaml config)"

required_services=(
  ai-agent-observability-mlflow-postgres
  ai-agent-observability-mlflow-storage
  ai-agent-observability-mlflow
  ai-agent-observability-laminar-postgres
  ai-agent-observability-laminar-clickhouse
  ai-agent-observability-laminar-rabbitmq
  ai-agent-observability-laminar-quickwit
  ai-agent-observability-laminar-app-server
  ai-agent-observability-laminar-frontend
  ai-agent-observability-laminar-bootstrap
  ai-agent-observability-otel-collector
)

for service_name in "${required_services[@]}"; do
  if ! grep -Fq "$service_name" <<<"$compose_output"; then
    printf 'missing rendered service/container: %s\n' "$service_name" >&2
    exit 1
  fi
done

if ! grep -Fq 'host_ip: 127.0.0.1' <<<"$compose_output"; then
  printf '%s\n' 'host bindings are not loopback-only' >&2
  exit 1
fi

for published_port in 15000 15667 14317 14318; do
  if ! grep -Fq "published: \"$published_port\"" <<<"$compose_output"; then
    printf 'missing published loopback port: %s\n' "$published_port" >&2
    exit 1
  fi
done

if grep -Fq 'host_ip: 0.0.0.0' <<<"$compose_output"; then
  printf '%s\n' 'a host port is exposed on all interfaces' >&2
  exit 1
fi

if ! grep -Fq 'external: true' <<<"$compose_output"; then
  printf '%s\n' 'the runtime network is not declared external' >&2
  exit 1
fi

if ! git check-ignore -q deploy/.env; then
  printf '%s\n' 'deploy/.env is not ignored' >&2
  exit 1
fi

forbidden_pattern='anime[0-9]+|BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|/mnt/c/Users/|/home/timot/'
if git grep -nE "$forbidden_pattern" -- .; then
  printf '%s\n' 'repository contains a forbidden credential or personal path' >&2
  exit 1
fi

if find . -type f -not -path './.git/*' -name '*.py' -print -quit | grep -q .; then
  printf '%s\n' 'Python application source is outside this repository boundary' >&2
  exit 1
fi

printf '%s\n' 'Compose and repository invariants passed.'
