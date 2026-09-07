#!/usr/bin/env bash
# Static rendering only. Never starts containers or loads a deployment .env.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
command -v jq >/dev/null
if [[ -n ${COMPOSE_BINARY:-} ]]; then
  compose=("$COMPOSE_BINARY")
else
  compose=(docker compose)
fi
"${compose[@]}" --env-file deploy/.env.example -f deploy/compose.yaml config --format json |
  jq -e -f tests/compose-policy.jq >/dev/null
printf '%s\n' 'Parsed Compose ports, service presence, protected mounts and telemetry defaults passed.'
