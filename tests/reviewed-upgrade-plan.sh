#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
planner="$repo_root/deploy/prepare-reviewed-upgrade.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

bash -n "$planner"
head="$(git -C "$repo_root" rev-parse HEAD)"

if OBSERVABILITY_EXPECTED_GIT_HEAD="$head" \
   "$planner" --plan --live-source-dir /safe-live >"$test_root/output" 2>"$test_root/error"; then
  printf '%s\n' 'planner accepted an extra path argument' >&2
  exit 1
fi
grep -Fq 'usage:' "$test_root/error"

if grep -Eq 'OBSERVABILITY_(LIVE_SOURCE_DIR|BACKUP_ROOT)|--(live-source-dir|backup-root)' "$planner"; then
  printf '%s\n' 'planner must not expose caller-controlled deployment or backup paths' >&2
  exit 1
fi

if OBSERVABILITY_EXPECTED_GIT_HEAD=0000000000000000000000000000000000000000 \
   "$planner" --plan >"$test_root/output" 2>"$test_root/error"; then
  printf '%s\n' 'planner accepted a mismatched candidate SHA' >&2
  exit 1
fi
grep -Fq 'candidate HEAD does not match' "$test_root/error"

if [[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  OBSERVABILITY_EXPECTED_GIT_HEAD="$head" \
  "$planner" --plan >"$test_root/output"
  grep -Fq "candidate_head=$head" "$test_root/output"
  grep -Fq 'mutation=not-authorized-by-this-script' "$test_root/output"
  grep -Fq '/usr/local/sbin/ai-agent-observability-reviewed-upgrade' "$test_root/output"
else
  if OBSERVABILITY_EXPECTED_GIT_HEAD="$head" \
     "$planner" --plan >"$test_root/output" 2>"$test_root/error"; then
    printf '%s\n' 'planner accepted a dirty candidate checkout' >&2
    exit 1
  fi
  grep -Fq 'candidate checkout is dirty' "$test_root/error"
fi

printf '%s\n' 'Reviewed upgrade plan guards passed.'
