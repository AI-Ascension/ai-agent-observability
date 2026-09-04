#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="$script_dir/.env"
project_name="ai-agent-observability"
network_name="ai-agent-observability-net"

new_uuid() {
  local value
  value="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${value:0:8}" \
    "${value:8:4}" \
    "${value:13:3}" \
    "$((16#${value:16:2} % 4 + 8))" \
    "${value:17:3}" \
    "${value:20:12}"
}

compose() {
  local compose_bake="${COMPOSE_BAKE:-false}"

  case "${COMPOSE_ENGINE:-docker}" in
    docker)
      COMPOSE_BAKE="$compose_bake" docker compose "$@"
      ;;
    podman)
      COMPOSE_BAKE="$compose_bake" podman compose "$@"
      ;;
    *)
      printf '%s\n' 'COMPOSE_ENGINE must be docker or podman' >&2
      exit 64
      ;;
  esac
}

ensure_network() {
  case "${COMPOSE_ENGINE:-docker}" in
    podman)
      if podman network inspect "$network_name" >/dev/null 2>&1; then
        if ! podman network inspect "$network_name" | grep -Fq '"isolate": "false"'; then
          printf '%s\n' "Podman network $network_name exists without isolate=false; remove it only after confirming it is dedicated to this stack." >&2
          exit 69
        fi
      else
        podman network create --opt isolate=false "$network_name" >/dev/null
      fi
      ;;
    docker)
      if [[ "${DOCKER_HOST:-}" == *podman.sock ]] && command -v podman >/dev/null 2>&1; then
        if podman network inspect "$network_name" >/dev/null 2>&1; then
          if ! podman network inspect "$network_name" | grep -Fq '"isolate": "false"'; then
            printf '%s\n' "Podman network $network_name exists without isolate=false; remove it only after confirming it is dedicated to this stack." >&2
            exit 69
          fi
        else
          podman network create --opt isolate=false "$network_name" >/dev/null
        fi
      else
        docker network inspect "$network_name" >/dev/null 2>&1 || docker network create --driver bridge "$network_name" >/dev/null
      fi
      ;;
  esac
}

command -v openssl >/dev/null || {
  printf '%s\n' 'openssl is required to generate deployment secrets' >&2
  exit 69
}

case "${COMPOSE_ENGINE:-docker}" in
  docker) command -v docker >/dev/null || { printf '%s\n' 'docker is required' >&2; exit 69; } ;;
  podman) command -v podman >/dev/null || { printf '%s\n' 'podman is required' >&2; exit 69; } ;;
esac

cd "$script_dir"

if [[ -e "$env_file" ]]; then
  chmod 600 "$env_file"
  printf '%s\n' 'Using the existing deploy/.env; it was not overwritten.'
else
  bind_address="${BIND_ADDRESS:-127.0.0.1}"
  mlflow_version="${MLFLOW_VERSION:-v3.16.0}"
  laminar_version="${LAMINAR_VERSION:-v0.2.3}"
  mlflow_port="${MLFLOW_PORT:-15000}"
  rustfs_api_port="${RUSTFS_API_PORT:-19000}"
  rustfs_console_port="${RUSTFS_CONSOLE_PORT:-19001}"
  laminar_http_port="${LAMINAR_HTTP_PORT:-18000}"
  laminar_grpc_port="${LAMINAR_GRPC_PORT:-18001}"
  laminar_realtime_port="${LAMINAR_REALTIME_PORT:-18002}"
  laminar_frontend_port="${LAMINAR_FRONTEND_PORT:-15667}"
  quickwit_http_port="${QUICKWIT_HTTP_PORT:-17280}"
  quickwit_otlp_port="${QUICKWIT_OTLP_PORT:-17281}"
  otel_grpc_port="${OTEL_GRPC_PORT:-14317}"
  otel_http_port="${OTEL_HTTP_PORT:-14318}"
  admin_email="${LAMINAR_ADMIN_EMAIL:-admin@ai-agent-observability.local}"
  workspace_id="$(new_uuid)"
  project_id="$(new_uuid)"
  mlflow_db_password="$(openssl rand -hex 32)"
  aws_access_key="$(openssl rand -hex 16)"
  aws_secret_key="$(openssl rand -hex 32)"
  laminar_db_password="$(openssl rand -hex 32)"
  rabbitmq_password="$(openssl rand -hex 32)"
  clickhouse_password="$(openssl rand -hex 32)"
  shared_secret="$(openssl rand -hex 32)"
  nextauth_secret="$(openssl rand -hex 32)"
  aead_secret="$(openssl rand -hex 32)"
  slack_secret="$(openssl rand -hex 32)"
  laminar_project_api_key="$(openssl rand -hex 32)"

  umask 077
  cat >"$env_file" <<EOF
BIND_ADDRESS=$bind_address
MLFLOW_VERSION=$mlflow_version
MLFLOW_PORT=$mlflow_port
MLFLOW_POSTGRES_USER=mlflow
MLFLOW_POSTGRES_PASSWORD=$mlflow_db_password
MLFLOW_POSTGRES_DB=mlflow
MLFLOW_BACKEND_STORE_URI=postgresql+psycopg2://mlflow:$mlflow_db_password@mlflow-postgres:5432/mlflow
MLFLOW_S3_BUCKET=mlflow
MLFLOW_EXPERIMENT_ID=0
RUSTFS_API_PORT=$rustfs_api_port
RUSTFS_CONSOLE_PORT=$rustfs_console_port
RUSTFS_CONSOLE_ENABLE=true
AWS_DEFAULT_REGION=us-east-1
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=$aws_access_key
AWS_SECRET_ACCESS_KEY=$aws_secret_key
LAMINAR_VERSION=$laminar_version
LAMINAR_HTTP_PORT=$laminar_http_port
LAMINAR_GRPC_PORT=$laminar_grpc_port
LAMINAR_REALTIME_PORT=$laminar_realtime_port
LAMINAR_FRONTEND_PORT=$laminar_frontend_port
LAMINAR_PUBLIC_URL=http://$bind_address:$laminar_frontend_port
POSTGRES_USER=laminar
POSTGRES_PASSWORD=$laminar_db_password
POSTGRES_DB=laminar
RABBITMQ_DEFAULT_USER=laminar
RABBITMQ_DEFAULT_PASS=$rabbitmq_password
CLICKHOUSE_USER=lmnr
CLICKHOUSE_PASSWORD=$clickhouse_password
CLICKHOUSE_RO_USER=lmnr
CLICKHOUSE_RO_PASSWORD=$clickhouse_password
SHARED_SECRET_TOKEN=$shared_secret
NEXTAUTH_SECRET=$nextauth_secret
AEAD_SECRET_KEY=$aead_secret
SLACK_ENCRYPTION_KEY=$slack_secret
LAMINAR_TELEMETRY_DISABLED=true
LAMINAR_PROJECT_API_KEY=$laminar_project_api_key
LAMINAR_PROJECT_ID=$project_id
LAMINAR_WORKSPACE_ID=$workspace_id
LAMINAR_PROJECT_NAME=AI-Ascension Agent Research
LAMINAR_WORKSPACE_NAME=AI-Ascension Research
LAMINAR_ADMIN_EMAIL=$admin_email
QUICKWIT_HTTP_PORT=$quickwit_http_port
QUICKWIT_OTLP_PORT=$quickwit_otlp_port
OTEL_GRPC_PORT=$otel_grpc_port
OTEL_HTTP_PORT=$otel_http_port
OPENAI_API_KEY=
LLM_PROVIDER=openai
LLM_BASE_URL=
LLM_API_KEY=
LLM_MODEL_SMALL=
LLM_MODEL_MEDIUM=
LLM_MODEL_LARGE=
RUST_LOG=info
EOF
  chmod 600 "$env_file"
  printf '%s\n' 'Created deploy/.env with fresh target-local secrets (mode 0600).'
fi

ensure_network
compose -p "$project_name" -f compose.yaml config --quiet
case "${COMPOSE_BUILD:-true}" in
  true)
    compose -p "$project_name" -f compose.yaml up -d --build
    ;;
  false)
    compose -p "$project_name" -f compose.yaml up -d --no-build
    ;;
  *)
    printf '%s\n' 'COMPOSE_BUILD must be true or false' >&2
    exit 64
    ;;
esac
printf '%s\n' 'AI-agent observability stack start requested.'
