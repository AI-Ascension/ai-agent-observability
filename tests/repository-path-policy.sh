#!/usr/bin/env bash
set -euo pipefail

# The legacy installation source is a documented migration input, not a
# general personal-home convention. This is the only permitted home path.
readonly allowed_legacy_source='/home/completetrain/ai-agent-observability'

reject_personal_path() {
  local value="$1" extended_allowed_path before_allowed after_allowed
  # This is the invariant's own Windows-hygiene matcher, not a host path.
  [[ "$value" == *'/mnt/c'[/]Users[/]* ]] && return 1
  # The legacy root is a token, never a prefix for a different personal path.
  extended_allowed_path="${allowed_legacy_source}[A-Za-z0-9_./-]"
  [[ "$value" =~ $extended_allowed_path ]] && return 0
  if [[ "$value" == *"$allowed_legacy_source"* ]]; then
    before_allowed="${value%%"$allowed_legacy_source"*}"
    after_allowed="${value#*"$allowed_legacy_source"}"
    [[ "$before_allowed" =~ [/]home[/][a-z_][a-z0-9_-]*/ || "$before_allowed" =~ [/]Users[/][a-z_][a-z0-9_-]*/ || \
       "$after_allowed" =~ [/]home[/][a-z_][a-z0-9_-]*/ || "$after_allowed" =~ [/]Users[/][a-z_][a-z0-9_-]*/ ]]
    return
  fi
  [[ "$value" == *[/]home[/]* || "$value" == *[/]Users[/]* ]]
}

permitted_legacy_path_file() {
  case "$1" in
    deploy/install-reviewed-upgrade-root-packet.sh|docs/REVIEWED_UPGRADE_INSTALLATION_PACKET.md|tests/root-install-packet.sh|tests/repository-path-policy.sh) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ "${1:-}" == --self-test ]]; then
  [[ "$#" -eq 1 ]] || { printf '%s\n' 'usage: repository-path-policy.sh [--self-test]' >&2; exit 64; }
  ! reject_personal_path "$allowed_legacy_source"
  reject_personal_path "$allowed_legacy_source/unexpected-child"
  permitted_legacy_path_file 'docs/REVIEWED_UPGRADE_INSTALLATION_PACKET.md'
  ! permitted_legacy_path_file 'docs/unrelated.md'
  fixture_root="$(mktemp -d)"
  trap 'rm -rf -- "$fixture_root"' EXIT
  git -C "$fixture_root" init --quiet
  mkdir -p "$fixture_root/docs" "$fixture_root/tests"
  printf "readonly allowed_legacy_source='%s'\n" "$allowed_legacy_source" \
    >"$fixture_root/tests/repository-path-policy.sh"
  printf '%s\n' "${allowed_legacy_source}-other/private" >"$fixture_root/docs/lookalike.md"
  git -C "$fixture_root" add docs/lookalike.md
  if REPOSITORY_PATH_POLICY_ROOT="$fixture_root" bash "$0" >"$fixture_root/output" 2>&1; then
    printf '%s\n' 'Path policy accepted a legacy-root lookalike.' >&2; exit 1
  fi
  grep -Fq 'forbidden personal path' "$fixture_root/output"
  rm -f -- "$fixture_root/docs/arbitrary-home.md"
  printf '# %s\n' "$allowed_legacy_source" >>"$fixture_root/tests/repository-path-policy.sh"
  git -C "$fixture_root" add -A
  if REPOSITORY_PATH_POLICY_ROOT="$fixture_root" bash "$0" >"$fixture_root/output" 2>&1; then
    printf '%s\n' 'Path policy accepted a tampered policy self-definition.' >&2; exit 1
  fi
  grep -Fq 'policy self-definition is not exact' "$fixture_root/output"
  rm -f -- "$fixture_root/docs/lookalike.md"
  printf "readonly allowed_legacy_source='%s'\n" "$allowed_legacy_source" \
    >"$fixture_root/tests/repository-path-policy.sh"
  printf '%s\n' "$allowed_legacy_source" >"$fixture_root/docs/unpermitted.md"
  git -C "$fixture_root" add -A
  if REPOSITORY_PATH_POLICY_ROOT="$fixture_root" bash "$0" >"$fixture_root/output" 2>&1; then
    printf '%s\n' 'Path policy accepted a legacy root in an unpermitted file.' >&2; exit 1
  fi
  grep -Fq 'legacy migration path is not permitted' "$fixture_root/output"
  rm -f -- "$fixture_root/docs/unpermitted.md"
  printf '/%s/fixture-user/unrelated\n' home >"$fixture_root/docs/arbitrary-home.md"
  git -C "$fixture_root" add -A
  if REPOSITORY_PATH_POLICY_ROOT="$fixture_root" bash "$0" >"$fixture_root/output" 2>&1; then
    printf '%s\n' 'Path policy accepted an arbitrary personal path.' >&2; exit 1
  fi
  grep -Fq 'forbidden personal path' "$fixture_root/output"
  printf '%s\n' 'Repository personal-path policy fixtures passed.'
  exit 0
fi

[[ "$#" -eq 0 ]] || { printf '%s\n' 'usage: repository-path-policy.sh [--self-test]' >&2; exit 64; }
repo_root="${REPOSITORY_PATH_POLICY_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '%s\n' 'policy root must be a Git worktree' >&2; exit 64; }
cd "$repo_root"
self_file='tests/repository-path-policy.sh'
readonly expected_self_definition="readonly allowed_legacy_source='$allowed_legacy_source'"
[[ "$(grep -Fxc "$expected_self_definition" "$self_file" || true)" == 1 ]] || {
  printf '%s\n' 'policy self-definition is not exact' >&2; exit 1;
}
[[ "$(grep -Foc "$allowed_legacy_source" "$self_file" || true)" == 1 ]] || {
  printf '%s\n' 'policy self-definition is not exact' >&2; exit 1;
}

while IFS= read -r entry; do
  content="${entry#*:*:}"
  if reject_personal_path "$content"; then
    printf 'repository contains a forbidden personal path: %s\n' "${entry%%:*}" >&2
    exit 1
  fi
done < <(git grep -nE '[/]home[/]|[/]Users[/]' -- . || true)

# Only migration-facing sources may name the exact legacy root. This separate
# allowlist keeps the exception auditable and prevents its reuse elsewhere.
while IFS= read -r entry; do
  file="${entry%%:*}"
  if ! permitted_legacy_path_file "$file"; then
    printf 'legacy migration path is not permitted in: %s\n' "$file" >&2
    exit 1
  fi
done < <(git grep -nF "$allowed_legacy_source" -- . \
  || true)

printf '%s\n' 'Repository personal-path policy passed.'
