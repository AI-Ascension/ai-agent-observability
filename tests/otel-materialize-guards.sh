#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
materializer="$repo_root/deploy/materialize-otel-source.sh"
test_root="$(mktemp -d)"
candidate_env_path="$repo_root/deploy/.env"
candidate_env_created=false
# This fixture creates an ignored candidate .env to prove that materialization
# never transfers it.  The candidate worktree can be shared by independently
# launched gates, so hold one cross-process lock before inspecting, creating,
# or removing that shared ignored file.
candidate_env_lock_dir="${TMPDIR:-/tmp}/ai-agent-observability-materialize-guards"
candidate_env_lock_key="$(printf '%s' "$(readlink -f -- "$repo_root")" | sha256sum | awk '{print $1}')"
mkdir -p -- "$candidate_env_lock_dir"
[[ -d "$candidate_env_lock_dir" && ! -L "$candidate_env_lock_dir" ]] || {
  printf '%s\n' 'materializer fixture lock path is not a directory' >&2
  exit 1
}
chmod 0700 -- "$candidate_env_lock_dir"
[[ "$(stat -c '%a:%u' -- "$candidate_env_lock_dir")" == "700:$UID" ]] || {
  printf '%s\n' 'materializer fixture lock directory is not private to this user' >&2
  exit 1
}
exec {candidate_env_lock_fd}>"$candidate_env_lock_dir/$candidate_env_lock_key.lock"
flock "$candidate_env_lock_fd"
cleanup() {
  rm -rf -- "$test_root"
  if [[ "$candidate_env_created" == true ]]; then
    rm -f -- "$candidate_env_path"
  fi
}
trap cleanup EXIT

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

fake_bin="$test_root/bin"
fake_state="$test_root/fake-state"
mkdir -p -- "$fake_bin" "$fake_state"
cat >"$fake_bin/podman" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="${FAKE_STATE_DIR:?}"
if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
  case "${FAKE_CANDIDATE_USER_MODE:-valid}" in
    valid) printf '%s\n' '10001:10001' ;;
    empty) printf '\n' ;;
    bare) printf '%s\n' '10001' ;;
    drift) printf '%s\n' '10001:10002' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
if [[ "${1:-}" == run ]]; then
  volume=''
  user=''
  volume_count=0
  user_count=0
  saw_pull_never=false
  saw_network_none=false
  saw_read_only=false
  saw_cap_drop_all=false
  saw_no_new_privileges=false
  args=("$@")
  for ((index=1; index < ${#args[@]}; index++)); do
    case "${args[index]}" in
      --pull=never) saw_pull_never=true ;;
      --network=none) saw_network_none=true ;;
      --read-only) saw_read_only=true ;;
      --cap-drop=ALL) saw_cap_drop_all=true ;;
      --security-opt=no-new-privileges) saw_no_new_privileges=true ;;
      --user)
        user_count=$((user_count + 1))
        user="${args[index + 1]}"
        ((index += 1))
        ;;
      --volume)
        volume_count=$((volume_count + 1))
        volume="${args[index + 1]}"
        ((index += 1))
        ;;
    esac
  done
  [[ "$saw_pull_never" == true && "$saw_network_none" == true && \
     "$saw_read_only" == true && "$saw_cap_drop_all" == true && \
     "$saw_no_new_privileges" == true ]] || exit 20
  [[ "$user_count" == 1 && "$user" == '10001:10001' ]] || exit 21
  [[ "$volume_count" == 1 && "$volume" == *:/otel-config:ro ]] || exit 22
  source_path="${volume%:/otel-config:ro}"
  [[ -n "$source_path" && -f "$source_path" ]] || exit 22
  mode="$(stat -c '%a' "$source_path")"
  # The reader has a direct file bind. It must judge the other-read bit for
  # UID:GID 10001, without walking the candidate checkout's parent directory.
  (( (8#$mode & 4) != 0 )) || exit 23
  exit 0
fi
printf 'unsupported fixture podman invocation: %s\n' "$*" >&2
exit 1
FAKE
chmod +x "$fake_bin/podman"

candidate_head="$(git -C "$repo_root" rev-parse HEAD)"
candidate_env=(
  OTEL_CANDIDATE_IMAGE_REF=fixture-candidate:10001
  OTEL_CANDIDATE_READER_IMAGE=fixture-reader:stable
  OTEL_CANDIDATE_READER_ENGINE=podman
  OTEL_CANDIDATE_READER_TIMEOUT_SECONDS=5
  FAKE_STATE_DIR="$fake_state"
)

if [[ -e "$candidate_env_path" ]]; then
  printf '%s\n' 'materializer fixture requires no pre-existing candidate deploy/.env' >&2
  exit 1
fi
candidate_secret='CANDIDATE_SECRET_MUST_NOT_REACH_TARGET=ignored-fixture-value'
printf '%s\n' "$candidate_secret" >"$candidate_env_path"
chmod 0600 "$candidate_env_path"
candidate_env_created=true
git check-ignore -q "$candidate_env_path"
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || \
  { printf '%s\n' 'ignored candidate deploy/.env made the checkout dirty' >&2; exit 1; }

run_materialize_failure() {
  local label="$1"
  local expected="$2"
  local target="$3"
  local backup="$4"
  local output_prefix="$test_root/negative-$label"
  local status=0
  if env "${candidate_env[@]}" PATH="$fake_bin:$PATH" \
      OTEL_LIVE_SOURCE_DIR="$target" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup" \
      OTEL_EXPECTED_GIT_HEAD="$candidate_head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
      "$materializer" --materialize >"$output_prefix.out" 2>"$output_prefix.err"; then
    printf 'materializer unexpectedly accepted fixture: %s\n' "$label" >&2
    exit 1
  else
    status=$?
  fi
  [[ "$status" != 0 ]] || exit 1
  grep -Fq "$expected" "$output_prefix.err" || {
    cat "$output_prefix.err" >&2
    printf 'fixture did not report expected guard: %s\n' "$label" >&2
    exit 1
  }
  [[ ! -e "$target/deploy/.otel-source-manifest.json" ]] || exit 1
  [[ ! -d "$backup" || -z "$(find "$backup" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]] || exit 1
}

target="$test_root/live"
backup_root="$test_root/backups"
make_target "$target"
config_inode="$(stat -c '%d:%i' "$target/deploy/otel-collector.yaml")"
compose_inode="$(stat -c '%d:%i' "$target/deploy/compose.yaml")"
env_inode="$(stat -c '%d:%i' "$target/deploy/.env")"
env_hash="$(sha256sum "$target/deploy/.env" | awk '{print $1}')"
env_mode="$(stat -c '%a' "$target/deploy/.env")"
env_uid="$(stat -c '%u' "$target/deploy/.env")"
env_gid="$(stat -c '%g' "$target/deploy/.env")"

materialize_env=(
  "${candidate_env[@]}"
  PATH="$fake_bin:$PATH"
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
[[ "$(stat -c '%a' "$target/deploy/.env")" == "$env_mode" ]] || exit 1
[[ "$(stat -c '%u' "$target/deploy/.env")" == "$env_uid" ]] || exit 1
[[ "$(stat -c '%g' "$target/deploy/.env")" == "$env_gid" ]] || exit 1
if grep -Fq "$candidate_secret" "$target/deploy/.env"; then
  printf '%s\n' 'candidate deploy/.env was copied into the live target' >&2
  exit 1
fi
[[ -f "$target/deploy/.otel-source-manifest.json" ]] || exit 1
[[ -f "$backup_dir/original-tree.tar" && -f "$backup_dir/original-tree.tar.sha256" && \
   -f "$backup_dir/candidate-bind-state.json" ]] || exit 1
[[ "$(jq -r '.config_user' "$target/deploy/.otel-source-manifest.json")" == '10001:10001' ]] || exit 1
for field in uid gid mode sha256; do
  jq -e ".config_source.$field == .config_bind.$field" "$target/deploy/.otel-source-manifest.json" >/dev/null || exit 1
done
jq -e '[.files[] | select(.path == "deploy/.env")] | length == 0' \
  "$target/deploy/.otel-source-manifest.json" >/dev/null || exit 1
[[ "$(jq -r '.entries[] | select(.path == "deploy/otel-collector.yaml") | .uid' "$backup_dir/original-bind-state.json")" == "$(stat -c '%u' "$target/deploy/otel-collector.yaml")" ]] || exit 1
[[ "$(jq -r '.entries[] | select(.path == "deploy/otel-collector.yaml") | .uid' "$backup_dir/candidate-bind-state.json")" == "$(stat -c '%u' "$target/deploy/otel-collector.yaml")" ]] || exit 1

env_replace_bin="$test_root/env-replace-bin"
mkdir -p -- "$env_replace_bin"
cat >"$env_replace_bin/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -Eeuo pipefail

real_tar="${OTEL_REAL_TAR:?}"
target="${OTEL_ENV_ARCHIVE_TARGET:?}"
saw_extract=false
saw_env_exclude=false
selected_env=false
saw_bound_compose=false
saw_bound_config=false
extract_root=''
args=("$@")
for ((index=0; index < ${#args[@]}; index++)); do
  argument="${args[index]}"
  case "$argument" in
    -xpf) saw_extract=true ;;
    --exclude=./deploy/.env|--exclude=deploy/.env) saw_env_exclude=true ;;
    ./deploy/.env|deploy/.env) selected_env=true ;;
    ./deploy/compose.yaml|deploy/compose.yaml) saw_bound_compose=true ;;
    ./deploy/otel-collector.yaml|deploy/otel-collector.yaml) saw_bound_config=true ;;
    -C)
      extract_root="${args[index + 1]}"
      ((index += 1))
      ;;
  esac
done
if [[ "$saw_extract" == true && "$selected_env" == true ]]; then
  printf '%s\n' 'recovery tar selected target-local deploy/.env' >&2
  exit 81
fi
if [[ "$saw_extract" == true && "$extract_root" == "$target" && "$saw_env_exclude" != true ]]; then
  printf '%s\n' 'recovery tar did not exclude target-local deploy/.env' >&2
  exit 83
fi
if [[ "$saw_extract" == true && "$extract_root" != "$target" && \
      ( "$saw_bound_compose" != true || "$saw_bound_config" != true ) ]]; then
  printf '%s\n' 'recovery tar did not restrict scratch extraction to strict bind files' >&2
  exit 82
fi
"$real_tar" "$@"
# Make archive replacement behavior deterministic.  A rollback that fails to
# exclude target-local .env must fail its final strict bind check; the repaired
# command never enters this branch.  No secret bytes are emitted.
if [[ "$saw_extract" == true && "$extract_root" == "$target" && "$saw_env_exclude" != true ]]; then
  cp -- "$target/deploy/.env" "$target/deploy/.env.fixture-replacement"
  chmod --reference="$target/deploy/.env" "$target/deploy/.env.fixture-replacement"
  mv -f -- "$target/deploy/.env.fixture-replacement" "$target/deploy/.env"
fi
FAKE_TAR
chmod +x "$env_replace_bin/tar"

env "${candidate_env[@]}" PATH="$env_replace_bin:$fake_bin:$PATH" \
  OTEL_REAL_TAR="$(command -v tar)" OTEL_ENV_ARCHIVE_TARGET="$target" \
  OTEL_LIVE_SOURCE_DIR="$target" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_root" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_dir" \
  "$materializer" --rollback
[[ ! -e "$target/deploy/.otel-source-manifest.json" ]] || exit 1
[[ "$(cat "$target/deploy/otel-collector.yaml")" == 'original config' ]] || exit 1
[[ "$(cat "$target/deploy/compose.yaml")" == 'original compose' ]] || exit 1
[[ "$(stat -c '%a' "$target/deploy/otel-collector.yaml")" == 777 ]] || exit 1
[[ "$(stat -c '%d:%i' "$target/deploy/otel-collector.yaml")" == "$config_inode" ]] || exit 1
[[ "$(stat -c '%d:%i' "$target/deploy/.env")" == "$env_inode" ]] || exit 1
[[ "$(sha256sum "$target/deploy/.env" | awk '{print $1}')" == "$env_hash" ]] || exit 1
[[ "$(stat -c '%a' "$target/deploy/.env")" == "$env_mode" ]] || exit 1
[[ "$(stat -c '%u' "$target/deploy/.env")" == "$env_uid" ]] || exit 1
[[ "$(stat -c '%g' "$target/deploy/.env")" == "$env_gid" ]] || exit 1

# An extraction failure after the candidate tree has been written must restore
# the original target completely. The ignored candidate .env is present during
# this run, but it must never reach the target or any diagnostic output.
tar_fail_bin="$test_root/tar-fail-bin"
mkdir -p -- "$tar_fail_bin"
tar_fail_marker="$test_root/tar-fail-marker"
cat >"$tar_fail_bin/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -Eeuo pipefail
real_tar="${OTEL_REAL_TAR:?}"
marker="${OTEL_FAIL_TAR_MARKER:?}"
if [[ ! -e "$marker" ]]; then
  for argument in "$@"; do
    if [[ "$argument" == '-xpf' ]]; then
      "$real_tar" "$@"
      : >"$marker"
      exit 97
    fi
  done
fi
exec "$real_tar" "$@"
FAKE_TAR
chmod +x "$tar_fail_bin/tar"
target_failed_extract="$test_root/live-failed-extract"
backup_failed_extract="$test_root/backups-failed-extract"
make_target "$target_failed_extract"
failed_env_inode="$(stat -c '%d:%i' "$target_failed_extract/deploy/.env")"
failed_env_hash="$(sha256sum "$target_failed_extract/deploy/.env" | awk '{print $1}')"
failed_env_mode="$(stat -c '%a' "$target_failed_extract/deploy/.env")"
failed_env_uid="$(stat -c '%u' "$target_failed_extract/deploy/.env")"
failed_env_gid="$(stat -c '%g' "$target_failed_extract/deploy/.env")"
if env "${candidate_env[@]}" PATH="$tar_fail_bin:$fake_bin:$PATH" \
    OTEL_REAL_TAR="$(command -v tar)" OTEL_FAIL_TAR_MARKER="$tar_fail_marker" \
    OTEL_LIVE_SOURCE_DIR="$target_failed_extract" \
    OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_failed_extract" \
    OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
    "$materializer" --materialize >"$test_root/failed-extract.out" 2>"$test_root/failed-extract.err"; then
  printf '%s\n' 'materializer unexpectedly accepted the extraction failure fixture' >&2
  exit 1
fi
[[ -e "$tar_fail_marker" ]] || exit 1
[[ "$(cat "$target_failed_extract/deploy/compose.yaml")" == 'original compose' ]] || exit 1
[[ "$(cat "$target_failed_extract/deploy/otel-collector.yaml")" == 'original config' ]] || exit 1
[[ "$(stat -c '%d:%i' "$target_failed_extract/deploy/.env")" == "$failed_env_inode" ]] || exit 1
[[ "$(sha256sum "$target_failed_extract/deploy/.env" | awk '{print $1}')" == "$failed_env_hash" ]] || exit 1
[[ "$(stat -c '%a' "$target_failed_extract/deploy/.env")" == "$failed_env_mode" ]] || exit 1
[[ "$(stat -c '%u' "$target_failed_extract/deploy/.env")" == "$failed_env_uid" ]] || exit 1
[[ "$(stat -c '%g' "$target_failed_extract/deploy/.env")" == "$failed_env_gid" ]] || exit 1
[[ ! -e "$target_failed_extract/deploy/.otel-source-manifest.json" ]] || exit 1
[[ ! -e "$target_failed_extract/deploy/Dockerfile.otel" ]] || exit 1
if grep -R --binary-files=without-match -Fq "$candidate_secret" "$target_failed_extract"; then
  printf '%s\n' 'candidate deploy/.env leaked into the failed target' >&2
  exit 1
fi

# A direct bind reader remains valid when the candidate checkout's parent
# directory denies traversal. A host-side `test -r candidate/path` would give
# the wrong answer for this case.
target_parent="$test_root/live-parent"
backup_parent="$test_root/backups-parent"
make_target "$target_parent"
chmod 0700 "$repo_root/deploy"
env "${candidate_env[@]}" PATH="$fake_bin:$PATH" \
  OTEL_LIVE_SOURCE_DIR="$target_parent" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_parent" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
  "$materializer" --materialize >/dev/null
chmod 0755 "$repo_root/deploy"

# A secure mode that is unreadable to UID:GID 10001 is rejected before a
# backup/pin or target manifest is created.
target_secure="$test_root/live-secure"
backup_secure="$test_root/backups-secure"
make_target "$target_secure"
chmod 0600 "$repo_root/deploy/otel-collector.yaml"
run_materialize_failure secure-config 'not readable by its actual Config.User' "$target_secure" "$backup_secure"
chmod 0644 "$repo_root/deploy/otel-collector.yaml"

target_empty="$test_root/live-empty-user"
backup_empty="$test_root/backups-empty-user"
make_target "$target_empty"
if env "${candidate_env[@]}" PATH="$fake_bin:$PATH" FAKE_CANDIDATE_USER_MODE=empty \
    OTEL_LIVE_SOURCE_DIR="$target_empty" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_empty" \
    OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
    "$materializer" --materialize >"$test_root/empty-user.out" 2>"$test_root/empty-user.err"; then
  printf '%s\n' 'materializer accepted an empty candidate Config.User' >&2
  exit 1
fi
grep -Fq 'explicit UID:GID pair' "$test_root/empty-user.err"
[[ ! -e "$target_empty/deploy/.otel-source-manifest.json" ]] || exit 1

target_bare="$test_root/live-bare-user"
backup_bare="$test_root/backups-bare-user"
make_target "$target_bare"
if env "${candidate_env[@]}" PATH="$fake_bin:$PATH" FAKE_CANDIDATE_USER_MODE=bare \
    OTEL_LIVE_SOURCE_DIR="$target_bare" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_bare" \
    OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
    "$materializer" --materialize >"$test_root/bare-user.out" 2>"$test_root/bare-user.err"; then
  printf '%s\n' 'materializer accepted a bare candidate Config.User' >&2
  exit 1
fi
grep -Fq 'explicit UID:GID pair' "$test_root/bare-user.err"
[[ ! -e "$target_bare/deploy/.otel-source-manifest.json" ]] || exit 1

target_drift="$test_root/live-drift-user"
backup_drift="$test_root/backups-drift-user"
make_target "$target_drift"
if env "${candidate_env[@]}" PATH="$fake_bin:$PATH" FAKE_CANDIDATE_USER_MODE=drift \
    OTEL_LIVE_SOURCE_DIR="$target_drift" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_drift" \
    OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
    "$materializer" --materialize >"$test_root/drift-user.out" 2>"$test_root/drift-user.err"; then
  printf '%s\n' 'materializer accepted a drifted candidate Config.User' >&2
  exit 1
fi
grep -Fq 'candidate image Config.User must be 10001:10001' "$test_root/drift-user.err"
[[ ! -e "$target_drift/deploy/.otel-source-manifest.json" ]] || exit 1

target_changed="$test_root/live-changed"
backup_changed="$test_root/backups-changed"
make_target "$target_changed"
output="$(env "${candidate_env[@]}" PATH="$fake_bin:$PATH" OTEL_LIVE_SOURCE_DIR="$target_changed" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_changed" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
  "$materializer" --materialize)"
backup_changed_dir="${output##*original backup=}"
printf '%s\n' 'unreviewed concurrent edit' >"$target_changed/deploy/compose.yaml"
if env "${candidate_env[@]}" PATH="$fake_bin:$PATH" OTEL_LIVE_SOURCE_DIR="$target_changed" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_changed" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_changed_dir" \
  "$materializer" --rollback >"$test_root/rollback.out" 2>"$test_root/rollback.err"; then
  printf '%s\n' 'rollback accepted a changed materialized source' >&2
  exit 1
fi
grep -Fq 'tree manifest content changed' "$test_root/rollback.err"
grep -Fq 'unreviewed concurrent edit' "$target_changed/deploy/compose.yaml"

target_false_pin="$test_root/live-false-pin"
backup_false_pin="$test_root/backups-false-pin"
make_target "$target_false_pin"
output="$(env "${candidate_env[@]}" PATH="$fake_bin:$PATH" \
  OTEL_LIVE_SOURCE_DIR="$target_false_pin" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_false_pin" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
  "$materializer" --materialize)"
backup_false_pin_dir="${output##*original backup=}"
cp -- "$target_false_pin/deploy/otel-collector.yaml" "$target_false_pin/deploy/config-replacement"
mv -- "$target_false_pin/deploy/config-replacement" "$target_false_pin/deploy/otel-collector.yaml"
if env OTEL_LIVE_SOURCE_DIR="$target_false_pin" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_false_pin" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_false_pin_dir" \
  "$materializer" --rollback >"$test_root/false-pin.out" 2>"$test_root/false-pin.err"; then
  printf '%s\n' 'rollback accepted a false Collector config bind pin' >&2
  exit 1
fi
grep -Fq 'bind-source inode changed' "$test_root/false-pin.err"

target_mode="$test_root/live-mode-drift"
backup_mode="$test_root/backups-mode-drift"
make_target "$target_mode"
output="$(env "${candidate_env[@]}" PATH="$fake_bin:$PATH" \
  OTEL_LIVE_SOURCE_DIR="$target_mode" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_mode" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
  "$materializer" --materialize)"
backup_mode_dir="${output##*original backup=}"
chmod 0600 "$target_mode/deploy/otel-collector.yaml"
if env OTEL_LIVE_SOURCE_DIR="$target_mode" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_mode" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_mode_dir" \
  "$materializer" --rollback >"$test_root/uidgid.out" 2>"$test_root/uidgid.err"; then
  printf '%s\n' 'rollback accepted source/bind mode drift' >&2
  exit 1
fi
grep -Eq 'tree manifest mode changed|bind-source mode changed|source/bind metadata changed' "$test_root/uidgid.err"

target_uidgid="$test_root/live-uidgid-drift"
backup_uidgid="$test_root/backups-uidgid-drift"
make_target "$target_uidgid"
output="$(env "${candidate_env[@]}" PATH="$fake_bin:$PATH" \
  OTEL_LIVE_SOURCE_DIR="$target_uidgid" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_uidgid" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_SOURCE_MATERIALIZE_APPROVED=true \
  "$materializer" --materialize)"
backup_uidgid_dir="${output##*original backup=}"
if chown 10001:10001 "$target_uidgid/deploy/otel-collector.yaml" 2>/dev/null; then
  uidgid_drift_mode=live
else
  # Unprivileged CI cannot change ownership. Alter the captured expectation so
  # the strict restore check still exercises the UID/GID pin deterministically.
  jq '(.entries[] | select(.path == "deploy/otel-collector.yaml") | .uid) += 1' \
    "$backup_uidgid_dir/original-bind-state.json" >"$test_root/original-bind-state.json"
  mv -- "$test_root/original-bind-state.json" "$backup_uidgid_dir/original-bind-state.json"
  uidgid_drift_mode=captured
fi
if env OTEL_LIVE_SOURCE_DIR="$target_uidgid" OTEL_MATERIALIZATION_BACKUP_ROOT="$backup_uidgid" \
  OTEL_EXPECTED_GIT_HEAD="$head" OTEL_MATERIALIZATION_BACKUP_DIR="$backup_uidgid_dir" \
  "$materializer" --rollback >"$test_root/uidgid-drift.out" 2>"$test_root/uidgid-drift.err"; then
  printf '%s\n' "rollback accepted $uidgid_drift_mode source/bind UID/GID drift" >&2
  exit 1
fi
grep -Eq 'bind-source uid/gid changed|source/bind metadata changed' "$test_root/uidgid-drift.err"

printf '%s\n' 'OTel source materialization guard fixtures passed.'
