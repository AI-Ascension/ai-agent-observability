#!/usr/bin/env bash
set -euo pipefail
unset -f docker openssl
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/repo/tests/fixtures" "$test_root/repo/deploy/laminar"
cp "$repo_root/tests/fixtures/docker-compose-config" "$test_root/bin/docker"
chmod +x "$test_root/bin/docker"
export PATH="$test_root/bin:$PATH"
TEST_BINDING=loopback bash "$repo_root/tests/compose-invariants.sh" >"$test_root/output" 2>&1
for binding in omitted 0.0.0.0 192.0.2.1 '"::"' '"::1"'; do
  if TEST_BINDING="$binding" bash "$repo_root/tests/compose-invariants.sh" >"$test_root/output" 2>&1; then
    printf 'Compose validation accepted forbidden binding: %s\n' "$binding" >&2
    exit 1
  fi
  grep -Fq 'host bindings are not loopback-only' "$test_root/output"
done

# Inherited functions must never bypass the initializer's command fixtures.
(
  docker() { printf '%s\n' 'Unexpected inherited Docker function' >&2; return 97; }
  openssl() { printf '%s\n' 'Unexpected inherited OpenSSL function' >&2; return 97; }
  export -f docker openssl
  bash "$repo_root/tests/bootstrap.sh" >"$test_root/output" 2>&1
)

# Mutation probe: the bootstrap test must fail if the error leaks the identity.
cp "$repo_root/tests/bootstrap.sh" "$test_root/repo/tests/"
cp "$repo_root/tests/fixtures/"{docker,openssl} "$test_root/repo/tests/fixtures/"
cp "$repo_root/deploy/init.sh" "$test_root/repo/deploy/"
sed 's/canonical UUID; correct/canonical UUID; 01234567 correct/' \
  "$repo_root/deploy/laminar/bootstrap-project-key.sh" \
  >"$test_root/repo/deploy/laminar/bootstrap-project-key.sh"
if bash "$test_root/repo/tests/bootstrap.sh" >"$test_root/output" 2>&1; then
  printf '%s\n' 'Bootstrap validation accepted an identity leak.' >&2
  exit 1
fi
grep -Fq 'Invalid-identity error exposed the identity value.' "$test_root/output"
printf '%s\n' 'Validation rejects unsafe bindings and bootstrap identity leaks (fixtures only).'
