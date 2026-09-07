#!/usr/bin/env bash
# Static rendering only. Never starts containers or loads a deployment .env.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
command -v jq >/dev/null
expected_compose_version='2.39.4'
expected_jq_version='1.8.1'
if [[ -n ${COMPOSE_BINARY:-} ]]; then
  compose=("$COMPOSE_BINARY")
else
  compose=(docker compose)
fi

# Keep shell variables, Docker context settings and credentials out of Compose
# interpolation. The only interpolation source for this canonical render is
# the checked-in example file named below.
isolated_env=(env -i PATH="$PATH" HOME=/tmp)
compose_version="$("${isolated_env[@]}" "${compose[@]}" version --short)"
[[ $compose_version == "$expected_compose_version" ]] || {
  printf 'Expected Compose %s, got %s\n' "$expected_compose_version" "$compose_version" >&2
  exit 1
}
jq_version="$(jq --version)"
[[ $jq_version == "jq-$expected_jq_version" ]] || {
  printf 'Expected jq %s, got %s\n' "$expected_jq_version" "$jq_version" >&2
  exit 1
}

"${isolated_env[@]}" "${compose[@]}" \
  --env-file "$repo_root/deploy/.env.example" -f "$repo_root/deploy/compose.yaml" \
  config --format json |
  jq -e --arg project_dir "$repo_root" \
    --slurpfile contract_file "$repo_root/tests/compose-contract.json" \
    -f "$repo_root/tests/compose-policy.jq" >/dev/null
printf 'Parsed bounded Compose topology with Compose %s and %s; ambient interpolation was excluded.\n' \
  "$compose_version" "$jq_version"
