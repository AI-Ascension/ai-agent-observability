#!/usr/bin/env bash
set -euo pipefail
# Imported shell functions take precedence over PATH fixtures.
unset -f docker openssl
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT
mkdir "$test_root/bin"
cp "$repo_root/tests/fixtures/openssl" "$repo_root/tests/fixtures/docker" "$test_root/bin/"
chmod +x "$test_root/bin/openssl" "$test_root/bin/docker"
export PATH="$test_root/bin:$PATH"
export COMPOSE_ENGINE=docker COMPOSE_BUILD=false DOCKER_HOST=

# Force each random variant deterministically through the complete initializer.
for variant in 8 9 a b; do
  case "$variant" in
    8) export UUID_TEST_BYTE=0 ;;
    9) export UUID_TEST_BYTE=1 ;;
    a) export UUID_TEST_BYTE=2 ;;
    b) export UUID_TEST_BYTE=3 ;;
  esac
  mkdir "$test_root/$variant"
  cp "$repo_root/deploy/init.sh" "$test_root/$variant/init.sh"
  bash "$test_root/$variant/init.sh" >/dev/null
  generated_env="$test_root/$variant/.env"
  for key in LAMINAR_WORKSPACE_ID LAMINAR_PROJECT_ID; do
    grep -Eq "^$key=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-${variant}[0-9a-f]{3}-[0-9a-f]{12}$" "$generated_env"
  done
  [[ $(stat -c %a "$generated_env") == 600 ]]
  before="$(sha256sum "$generated_env")"
  bash "$test_root/$variant/init.sh" >/dev/null
  [[ $(sha256sum "$generated_env") == "$before" ]]
done

export POSTGRES_USER=test POSTGRES_PASSWORD=test POSTGRES_DB=test
export LAMINAR_PROJECT_API_KEY
LAMINAR_PROJECT_API_KEY="$(printf '%064d' 0)"
export LAMINAR_PROJECT_NAME=test LAMINAR_WORKSPACE_NAME=test LAMINAR_ADMIN_EMAIL=test@example.invalid
valid_id=01234567-89ab-4def-8123-456789abcdef
for identity_name in LAMINAR_PROJECT_ID LAMINAR_WORKSPACE_ID; do
  export LAMINAR_PROJECT_ID="$valid_id" LAMINAR_WORKSPACE_ID="$valid_id"
  export "$identity_name=01234567-89ab-4def-10123-456789abcdef"
  status=0
  bash "$repo_root/deploy/laminar/bootstrap-project-key.sh" >"$test_root/output" 2>&1 || status=$?
  [[ $status == 64 ]]
  grep -Fq "$identity_name must be a canonical UUID" "$test_root/output"
  # Errors name the field, never its value or any deployment secrets.
  if grep -Fq '01234567' "$test_root/output"; then
    printf '%s\n' 'Invalid-identity error exposed the identity value.' >&2
    exit 1
  fi
done
printf '%s\n' 'Bootstrap UUID variants, environment preservation, and invalid identities passed.'
