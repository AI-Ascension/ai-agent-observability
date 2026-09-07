#!/usr/bin/env bash
# Render temporary Compose source mutations and assert that the normalized
# topology contract rejects each one. No daemon, container or real credential
# is used by this static parser test.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
command -v jq >/dev/null
test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT

if [[ -n ${COMPOSE_BINARY:-} ]]; then
  compose=("$COMPOSE_BINARY")
else
  compose=(docker compose)
fi
isolated_env=(env -i PATH="$PATH")
compose_version="$("${isolated_env[@]}" "${compose[@]}" version --short)"
[[ $compose_version == '2.39.4' ]] || {
  printf 'Expected Compose 2.39.4, got %s\n' "$compose_version" >&2
  exit 1
}

# Keep the copied project layout identical to deploy/ so Compose resolves the
# three reviewed configuration binds under the project directory we pass to jq.
mkdir -p "$test_root/deploy/laminar"
cp deploy/compose.yaml deploy/otel-collector.yaml "$test_root/deploy/"
cp deploy/Dockerfile.mlflow deploy/Dockerfile.laminar deploy/.dockerignore "$test_root/deploy/"
cp deploy/laminar/clickhouse-profiles-config.xml \
  deploy/laminar/clickhouse-server-config.xml "$test_root/deploy/laminar/"

render_source() {
  local override="$1"
  local output="$2"
  local compose_args=(
    --env-file "$repo_root/deploy/.env.example"
    -f "$test_root/deploy/compose.yaml"
  )
  if [[ -n $override ]]; then
    compose_args+=(-f "$override")
  fi
  "${isolated_env[@]}" "${compose[@]}" "${compose_args[@]}" config --format json > "$output"
}

policy() {
  jq -e --arg project_dir "$test_root" \
    --slurpfile contract_file "$repo_root/tests/compose-contract.json" \
    -f "$repo_root/tests/compose-policy.jq" "$1"
}

render_source '' "$test_root/base.json"
policy "$test_root/base.json" >/dev/null

write_override() {
  local kind="$1"
  local output="$2"
  case "$kind" in
    extra-service)
      cat > "$output" <<'EOF'
services:
  unapproved-egress:
    image: docker.io/library/alpine:3.22
    command: ["sleep", "infinity"]
    environment:
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
EOF
      ;;
    extra-environment)
      cat > "$output" <<'EOF'
services:
  mlflow:
    environment:
      EXTRA_SECRET: marker
EOF
      ;;
    host-bind)
      cat > "$output" <<'EOF'
services:
  laminar-clickhouse:
    volumes:
      - /etc/shadow:/run/host-shadow:ro
EOF
      ;;
    driver-bind)
      cat > "$output" <<'EOF'
volumes:
  laminar-clickhouse-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /etc/shadow
EOF
      ;;
    shared-network)
      cat > "$output" <<'EOF'
networks:
  default:
    name: shared-observability-network
    external: true
EOF
      ;;
    missing-port)
      cat > "$output" <<'EOF'
services:
  mlflow-storage:
    ports: !reset []
EOF
      ;;
    host-namespace)
      cat > "$output" <<'EOF'
services:
  mlflow:
    pid: host
EOF
      ;;
    all-capability)
      cat > "$output" <<'EOF'
services:
  mlflow:
    cap_add: [ALL]
EOF
      ;;
    frontend-telemetry)
      cat > "$output" <<'EOF'
services:
  laminar-frontend:
    environment:
      LAMINAR_TELEMETRY_DISABLED: "false"
      POSTHOG_TELEMETRY: "true"
EOF
      ;;
    entrypoint)
      cat > "$output" <<'EOF'
services:
  mlflow:
    entrypoint: ["sh", "-c", "exit 0"]
EOF
      ;;
    healthcheck)
      cat > "$output" <<'EOF'
services:
  mlflow:
    healthcheck:
      test: ["CMD", "sh", "-c", "exit 0"]
EOF
      ;;
    restart)
      cat > "$output" <<'EOF'
services:
  mlflow:
    restart: "no"
EOF
      ;;
    pull-policy)
      cat > "$output" <<'EOF'
services:
  mlflow:
    pull_policy: always
EOF
      ;;
    container-name)
      cat > "$output" <<'EOF'
services:
  mlflow:
    container_name: unapproved-mlflow
EOF
      ;;
    ulimits)
      cat > "$output" <<'EOF'
services:
  laminar-clickhouse:
    ulimits:
      nofile:
        soft: 1
        hard: 1
EOF
      ;;
    volume-option)
      cat > "$output" <<'EOF'
services:
  laminar-clickhouse:
    volumes:
      - type: volume
        source: laminar-clickhouse-data
        target: /var/lib/clickhouse
        volume:
          nocopy: true
EOF
      ;;
    bind-option)
      cat > "$output" <<'EOF'
services:
  laminar-clickhouse:
    volumes:
      - type: bind
        source: ./laminar/clickhouse-profiles-config.xml
        target: /etc/clickhouse-server/users.d/ai-agent-observability.xml
        read_only: true
        bind:
          create_host_path: true
          propagation: shared
EOF
      ;;
    port-option)
      cat > "$output" <<'EOF'
services:
  mlflow:
    ports:
      - host_ip: 127.0.0.1
        published: 15000
        target: 5000
        protocol: tcp
        app_protocol: http
EOF
      ;;
    *)
      printf 'unknown source mutation: %s\n' "$kind" >&2
      exit 1
      ;;
  esac
}

mutations=(
  extra-service
  extra-environment
  host-bind
  driver-bind
  shared-network
  missing-port
  host-namespace
  all-capability
  frontend-telemetry
  entrypoint
  healthcheck
  restart
  pull-policy
  container-name
  ulimits
  volume-option
  bind-option
  port-option
)
for mutation in "${mutations[@]}"; do
  override="$test_root/$mutation.yaml"
  output="$test_root/$mutation.json"
  write_override "$mutation" "$override"
  render_source "$override" "$output"
  if policy "$output" > "$test_root/result" 2>&1; then
    printf 'Accepted invalid Compose source mutation: %s\n' "$mutation" >&2
    exit 1
  fi
done

printf 'Compose source policy: 1 positive and %s negative rendered-source cases passed.\n' \
  "$(( ${#mutations[@]} ))"
