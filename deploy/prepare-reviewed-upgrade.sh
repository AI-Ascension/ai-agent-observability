#!/usr/bin/env bash
set -euo pipefail

# Print a non-mutating, exact-head deployment handoff. This script deliberately
# does not contact a container engine, target host, or .env file. The resulting
# plan is an approval input for a separately installed root-owned host wrapper.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
mode="${1:---plan}"
expected_head="${OBSERVABILITY_EXPECTED_GIT_HEAD:-}"

die() {
  printf 'reviewed upgrade preparation: %s\n' "$1" >&2
  exit 1
}

[[ "$mode" == --plan ]] || die "usage: $0 --plan"
[[ "$#" -eq 1 ]] || die "usage: $0 --plan"
[[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || die 'OBSERVABILITY_EXPECTED_GIT_HEAD must be a full lowercase SHA-1'
[[ -d "$repo_root/.git" || -f "$repo_root/.git" ]] || die 'candidate must be a Git checkout'

actual_head="$(git -C "$repo_root" rev-parse HEAD)"
[[ "$actual_head" == "$expected_head" ]] || die 'candidate HEAD does not match OBSERVABILITY_EXPECTED_GIT_HEAD'
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'candidate checkout is dirty'

for file in \
  deploy/compose.yaml \
  deploy/otel-collector.yaml \
  deploy/Dockerfile.otel \
  deploy/materialize-otel-source.sh \
  deploy/install-otel-health-probe.sh; do
  [[ -f "$repo_root/$file" && ! -L "$repo_root/$file" ]] || die "required candidate file is missing or a symlink: $file"
done

compose_sha="$(sha256sum "$repo_root/deploy/compose.yaml" | awk '{print $1}')"
collector_sha="$(sha256sum "$repo_root/deploy/otel-collector.yaml" | awk '{print $1}')"
dockerfile_sha="$(sha256sum "$repo_root/deploy/Dockerfile.otel" | awk '{print $1}')"

cat <<PLAN
schema=ai-agent-observability-reviewed-upgrade-plan-v1
candidate_head=$actual_head
candidate_compose_sha256=$compose_sha
candidate_collector_sha256=$collector_sha
candidate_dockerfile_sha256=$dockerfile_sha
mutation=not-authorized-by-this-script

Required root-owned host wrapper (not currently installed):
  /usr/local/sbin/ai-agent-observability-reviewed-upgrade \\
    --candidate-head $actual_head \\
    --candidate-compose-sha256 $compose_sha \\
    --candidate-collector-sha256 $collector_sha \\
    --candidate-dockerfile-sha256 $dockerfile_sha

The wrapper owns its fixed installation-time deployment and backup paths. It
must accept neither caller-provided paths from argv/environment nor paths
printed by this planner. It must create a mode-0700 backup outside the
deployment tree; invoke the reviewed materializer and its rollback only with
their explicit approval variables; snapshot the named project volumes before
an approved compose update; and refuse generic Podman, arbitrary Compose files,
volume deletion, or image pruning. It must emit sanitized
source/image/container identities and leave all secrets in the existing
mode-0600 target files.
PLAN
