#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

compose_output="$(docker compose --env-file deploy/.env.example -f deploy/compose.yaml config)"

# MLflow validates the full Host header, including the published port. Health
# probes bypass that validation, so a healthy container does not cover UI/API.
for allowed_host in localhost:15000 127.0.0.1:15000; do
  grep -Fq "$allowed_host" <<<"$compose_output"
done
override_output="$(MLFLOW_PORT=15001 docker compose --env-file deploy/.env.example -f deploy/compose.yaml config)"
for allowed_host in localhost:15001 127.0.0.1:15001; do
  grep -Fq "$allowed_host" <<<"$override_output"
done

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

# Compose renders one host_ip and published field for each explicit host bind.
# Check all bindings, including omitted host_ip (an all-interface default).
if ! awk '
  $1 == "host_ip:" { hosts++; if ($2 != "127.0.0.1") invalid = 1 }
  $1 == "published:" { ports++ }
  END { exit (invalid || ports == 0 || hosts != ports) }
' <<<"$compose_output"; then
  printf '%s\n' 'host bindings are not loopback-only' >&2
  exit 1
fi

for published_port in 15000 15667 14317 14318; do
  if ! grep -Fq "published: \"$published_port\"" <<<"$compose_output"; then
    printf 'missing published loopback port: %s\n' "$published_port" >&2
    exit 1
  fi
done

if ! grep -Fq 'external: true' <<<"$compose_output"; then
  printf '%s\n' 'the runtime network is not declared external' >&2
  exit 1
fi

if ! git check-ignore -q deploy/.env; then
  printf '%s\n' 'deploy/.env is not ignored' >&2
  exit 1
fi

# The Docker build context is deploy/, not the repository root.
grep -Fxq '.env' deploy/.dockerignore
grep -Fxq '.env.*' deploy/.dockerignore

forbidden_pattern='anime[0-9]+|BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|/mnt/c/Users/|/home/[a-z_][a-z0-9_-]*/|/Users/[a-z_][a-z0-9_-]*/'
if git grep -qE "$forbidden_pattern" -- . ':(exclude)tests/compose-invariants.sh'; then
  printf '%s\n' 'repository contains a forbidden credential or personal path' >&2
  exit 1
fi

if find . -type f -not -path './.git/*' -name '*.py' -print -quit | grep -q .; then
  printf '%s\n' 'Python application source is outside this repository boundary' >&2
  exit 1
fi

printf '%s\n' 'Compose and repository invariants passed.'
