#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
materializer="$repo_root/deploy/materialize-otel-source.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

bash -n "$materializer"
git -C "$repo_root" diff --check
head="$(git -C "$repo_root" rev-parse HEAD)"
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || \
  { printf '%s\n' 'materializer fixture requires a clean candidate checkout' >&2; exit 1; }

make_target() {
  local target="$1"
  mkdir -p -- "$target/deploy"
  printf '%s\n' 'original compose' >"$target/deploy/compose.yaml"
  printf '%s\n' 'original config' >"$target/deploy/otel-collector.yaml"
  printf '%s\n' 'ORIGINAL_SECRET=preserve' >"$target/deploy/.env"
  chmod 0777 "$target/deploy/compose.yaml" "$target/deploy/otel-collector.yaml"
  chmod 0600 "$target/deploy/.env"
}

target="$test_root/live"
backup_root="$test_root/backups"
make_target "$target"
config_inode="$(stat -c '%d:%i' "$target/deploy/otel-collector.yaml")"
compose_inode="$(stat -c '%d:%i' "$target/deploy/compose.yaml")"
env_inode="$(stat -c '%d:%i' "$target/deploy/.env")"
env_hash="$(sha256sum "$target/deploy/.env" | awk '{print $1}')"

materialize_env=(
  OTEL_LIVE_SOURCE_DIR="$target"
  OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_root"
  OTEL_EXPECTED_GIT_HEAD="$head"
  OTEL_SOURCE_MATERIALIZE_APPROVED=true
)
output="$(env "${materialize_env[@]}" "$materializer" --materialize)"
backup_dir="${output##*original backup=}"
[[ -d "$backup_dir" ]] || { printf '%s\n' 'materialization backup path was not emitted' >&2; exit 1; }
[[ "$(stat -c '%d:%i' "$target/deploy/otel-collector.yaml")" == "$config_inode" ]] || exit 1
[[ "$(stat -c '%d:%i' "$target/deploy/compose.yaml")" == "$compose_inode" ]] || exit 1
[[ "$(stat -c '%d:%i' "$target/deploy/.env")" == "$env_inode" ]] || exit 1
[[ "$(sha256sum "$target/deploy/.env" | awk '{print $1}')" == "$env_hash" ]] || exit 1
[[ -f "$target/deploy/.otel-source-manifest.json" ]] || exit 1
[[ -f "$backup_dir/original-tree.tar" && -f "$backup_dir/original-tree.tar.sha256" ]] || exit 1

env OTEL_LIVE_SOURCE_DIR="$target" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_root" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_dir" \
  "$materializer" --rollback
[[ ! -e "$target/deploy/.otel-source-manifest.json" ]] || exit 1
[[ "$(cat "$target/deploy/otel-collector.yaml")" == 'original config' ]] || exit 1
[[ "$(cat "$target/deploy/compose.yaml")" == 'original compose' ]] || exit 1
[[ "$(stat -c '%a' "$target/deploy/otel-collector.yaml")" == 777 ]] || exit 1
[[ "$(stat -c '%d:%i' "$target/deploy/otel-collector.yaml")" == "$config_inode" ]] || exit 1
[[ "$(stat -c '%d:%i' "$target/deploy/.env")" == "$env_inode" ]] || exit 1

target_changed="$test_root/live-changed"
backup_changed="$test_root/backups-changed"
make_target "$target_changed"
output="$(env OTEL_LIVE_SOURCE_DIR="$target_changed" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_changed" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
  "$materializer" --materialize)"
backup_changed_dir="${output##*original backup=}"
printf '%s\n' 'unreviewed concurrent edit' >"$target_changed/deploy/compose.yaml"
if env OTEL_LIVE_SOURCE_DIR="$target_changed" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_changed" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_changed_dir" \
  "$materializer" --rollback >"$test_root/rollback.out" 2>"$test_root/rollback.err"; then
  printf '%s\n' 'rollback accepted a changed materialized source' >&2
  exit 1
fi
grep -Fq 'tree manifest content changed' "$test_root/rollback.err"
grep -Fq 'unreviewed concurrent edit' "$target_changed/deploy/compose.yaml"

printf '%s\n' 'OTel source materialization guard fixtures passed.'
