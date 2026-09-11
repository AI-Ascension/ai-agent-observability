#!/bin/bash -p
set -Eeuo pipefail

# Root-only, bounded installation of the reviewed-upgrade packet. It prepares
# fixed paths only; it never invokes Compose, starts/stops a service, pulls an
# image, or materializes the candidate into the canonical live tree.
readonly expected_head='7c5f3eab18446dea7f1eeafb8427cbe574c1d199'
test_root="${ROOT_PACKET_TEST_ROOT:-}"
if [[ -n "$test_root" ]]; then
  [[ "${ROOT_PACKET_TEST_MODE:-}" == hermetic && "$test_root" == /tmp/root-packet-test.* ]] || exit 64
  [[ -d "$test_root" && ! -L "$test_root" && "$(stat -c '%u:%a' "$test_root")" =~ ^0:700$ ]] || exit 64
  path_prefix="$test_root"
else
  path_prefix=''
fi
readonly legacy_root="$path_prefix/home/completetrain/ai-agent-observability"
readonly reviewed_root="$path_prefix/srv/ai-agent-observability-reviewed"
readonly deployment_root="$reviewed_root/live"
readonly candidate_root="$reviewed_root/candidate/$expected_head"
readonly backup_root="$path_prefix/var/backups/ai-agent-observability-reviewed-upgrade"
partial_journal="$(dirname -- "$backup_root")/.ai-agent-observability-root-packet-partial-v3"
readonly partial_journal
readonly installed_wrapper="$path_prefix/usr/local/sbin/ai-agent-observability-reviewed-upgrade"
readonly install_config="$path_prefix/etc/ai-agent-observability-reviewed-upgrade.conf"
readonly manifest_name='.root-packet-installation-v1'
readonly rollback_state_name='.root-packet-installation-rollback-v2'
readonly baseline_compose_sha256='6a4f31c411d03e54a6d0d88ef0bc6d65fc18061e1adafc7af94d8f08c6dd7b6f'
readonly PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

die() { printf 'reviewed root packet installation: %s\n' "$1" >&2; exit 1; }
usage() { printf '%s\n' "usage: $0 --install | --rollback-install" >&2; exit 64; }
clean_git() { env -i PATH="$PATH" HOME=/nonexistent /usr/bin/git "$@"; }
trusted_path() {
  local input="$1" component current='' mode owner
  [[ "$input" == /* && -e "$input" && ! -L "$input" && "$(readlink -e -- "$input")" == "$input" ]] || return 1
  if [[ -n "$test_root" && ( "$input" == "$test_root" || "$input" == "$test_root/"* ) ]]; then
    current="$test_root"
    owner="$(stat -c '%u' -- "$current")"; mode="$(stat -c '%a' -- "$current")"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )) || return 1
    IFS=/ read -r -a components <<<"${input#"$test_root"/}"
  else
    IFS=/ read -r -a components <<<"${input#/}"
  fi
  for component in "${components[@]}"; do
    current="$current/$component"; [[ -e "$current" && ! -L "$current" ]] || return 1
    owner="$(stat -c '%u' -- "$current")"; mode="$(stat -c '%a' -- "$current")"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )) || return 1
  done
}
root_regular() { trusted_path "$1" && [[ -f "$1" && "$(stat -c '%u:%a' "$1")" =~ ^0: ]]; }
root_dir() { trusted_path "$1" && [[ -d "$1" && "$(stat -c '%u:%a' "$1")" =~ ^0: ]]; }
safe_new_path() { [[ ! -e "$1" && ! -L "$1" ]]; }
trusted_new_parent() { safe_new_path "$1" && trusted_path "$(dirname -- "$1")"; }
path_identity() { stat -c '%d:%i:%f' -- "$1"; }
prepare_new_roots() {
  # The intent journal is created in the already-trusted backup parent before
  # any destination. mkdirat below is bound to a no-follow parent descriptor,
  # closing the check-to-create pathname replacement window.
  /usr/bin/python3 -I - "$partial_journal" "$reviewed_root" "$(dirname -- "$candidate_root")" "$deployment_root" "$backup_root" <<'PY'
import os, stat, sys
journal, *targets = sys.argv[1:]
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
DIRECTORY = getattr(os, "O_DIRECTORY", 0)
def trusted_dir(path):
    anchor = os.environ.get("ROOT_PACKET_TEST_ROOT", "")
    if anchor and (path == anchor or path.startswith(anchor + "/")):
        fd = os.open(anchor, os.O_RDONLY | DIRECTORY | NOFOLLOW)
        parts = path[len(anchor):].split("/")
    else:
        fd = os.open("/", os.O_RDONLY | DIRECTORY)
        parts = path.split("/")
    try:
        for component in filter(None, parts):
            nextfd = os.open(component, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = nextfd
            info = os.fstat(fd)
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise RuntimeError("unsafe parent")
        return fd
    except BaseException:
        os.close(fd); raise
parent = os.path.dirname(journal)
pfd = trusted_dir(parent)
try:
    jfd = os.open(os.path.basename(journal), os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=pfd)
    with os.fdopen(jfd, "w", encoding="ascii", closefd=True) as out:
        out.write("schema=ai-agent-observability-root-packet-partial-v3\n")
        out.write("state=intent-recorded\n")
        out.write("targets=" + "|".join(targets) + "\n")
        out.flush(); os.fsync(out.fileno())
        for target in targets:
            parent, name = os.path.dirname(target), os.path.basename(target)
            dfd = trusted_dir(parent)
            try:
                try: os.mkdir(name, 0o700, dir_fd=dfd)
                except FileExistsError: raise RuntimeError("destination already exists")
                child = os.open(name, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=dfd)
                try:
                    info = os.fstat(child)
                    if info.st_uid != 0 or info.st_mode & 0o022: raise RuntimeError("created destination unsafe")
                    out.write("created=%s:%s:%s\n" % (target, info.st_dev, info.st_ino))
                    out.flush(); os.fsync(out.fileno())
                finally: os.close(child)
            finally: os.close(dfd)
except BaseException:
    raise
finally:
    os.close(pfd)
PY
}
record_partial_file() {
  # Append only an identity bound to the created regular object, flushing it
  # before the next operation can create another packet object.
  /usr/bin/python3 -I - "$partial_journal" "$1" <<'PY'
import os, stat, sys
journal, path = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0: raise RuntimeError("created file unsafe")
finally: os.close(fd)
jfd = os.open(journal, os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0))
try:
    os.write(jfd, ("created_file=%s:%s:%s\n" % (path, info.st_dev, info.st_ino)).encode("ascii"))
    os.fsync(jfd)
finally: os.close(jfd)
PY
}
tree_safe() {
  local unsafe
  unsafe="$(find "$1" \( -type l -o \( ! -type d -a ! -type f \) -o ! -user root -o -perm /022 \) -print -quit)" || return 1
  [[ -z "$unsafe" ]]
}
tree_digest() {
  tar --sort=name --format=posix --numeric-owner --mtime='UTC 1970-01-01' \
    --pax-option=delete=atime,delete=ctime -C "$(dirname -- "$1")" -cf - "$(basename -- "$1")" \
    | sha256sum | awk '{print $1}'
}
safe_copy_legacy() {
  # Descriptors, rather than user-owned pathnames, carry source data after
  # validation. Symlinks and special files are refused.
  /usr/bin/python3 -I - "$legacy_root" "$deployment_root" <<'PY'
import os, stat, sys
source, destination = sys.argv[1:]
NOFOLLOW, DIRECTORY = getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_DIRECTORY", 0)
def directory(path):
    fd = os.open("/", os.O_RDONLY | DIRECTORY)
    try:
        for part in filter(None, path.split("/")):
            next_fd = os.open(part, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = next_fd
        return fd
    except BaseException: os.close(fd); raise
def file_copy(source_fd, destination_fd, name, mode):
    listed = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
    if not stat.S_ISREG(listed.st_mode): raise RuntimeError("unsafe source entry")
    if listed.st_size > 64 * 1024 * 1024: raise RuntimeError("source file exceeds bounded copy size")
    src = os.open(name, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=source_fd)
    try:
        opened = os.fstat(src)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (listed.st_dev, listed.st_ino): raise RuntimeError("source entry changed during open")
        dst = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=destination_fd)
        try:
            copied = 0
            while data := os.read(src, 1048576):
                copied += len(data)
                if copied > listed.st_size: raise RuntimeError("source file grew during copy")
                view = memoryview(data)
                while view: view = view[os.write(dst, view):]
            if copied != listed.st_size: raise RuntimeError("source file changed size during copy")
            os.fchmod(dst, mode & ~0o022)
        finally: os.close(dst)
    finally: os.close(src)
def tree(source_fd, destination_fd, relative=()):
    with os.scandir(os.dup(source_fd)) as entries:
        for entry in entries:
            child = relative + (entry.name,)
            # The live tree is deliberately a non-Git source tree; the
            # candidate alone retains Git metadata for exact-head checks.
            if child == ("deploy", ".env") or child == (".git",): continue
            info = os.stat(entry.name, dir_fd=source_fd, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                os.mkdir(entry.name, 0o755, dir_fd=destination_fd)
                src = os.open(entry.name, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=source_fd)
                dst = os.open(entry.name, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=destination_fd)
                try:
                    opened = os.fstat(src)
                    if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino): raise RuntimeError("source entry changed during open")
                    tree(src, dst, child)
                finally: os.close(src); os.close(dst)
            elif stat.S_ISREG(info.st_mode): file_copy(source_fd, destination_fd, entry.name, stat.S_IMODE(info.st_mode))
            else: raise RuntimeError("unsafe source entry")
source_fd, destination_fd = directory(source), directory(destination)
try:
    tree(source_fd, destination_fd)
    src = os.open("deploy", os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=source_fd)
    dst = os.open("deploy", os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=destination_fd)
    try: file_copy(src, dst, ".env", 0o600)
    finally: os.close(src); os.close(dst)
finally: os.close(source_fd); os.close(destination_fd)
PY
}

mode="${1:-}"
[[ "$#" -eq 1 ]] || usage
[[ "$mode" == --install || "$mode" == --rollback-install ]] || usage
[[ "$(id -u)" -eq 0 ]] || die 'must run as root after the rootful installation entitlement is granted'

rollback_install() {
  local key value reviewed_id='' deployment_id='' candidate_id='' wrapper_id='' config_id='' reviewed_digest='' deployment_digest='' candidate_digest='' wrapper_digest='' config_digest=''
  local -A seen=()
  [[ ! -e "$partial_journal" && ! -L "$partial_journal" ]] || die 'partial installation journal exists; preserving data for manual reconciliation'
  root_dir "$backup_root" || die 'fixed backup root is absent or unsafe'
  root_regular "$backup_root/$manifest_name" || die 'installation manifest is absent or unsafe'
  [[ "$(stat -c '%a' "$backup_root/$manifest_name")" == 600 ]] || die 'installation manifest mode is unsafe'
  [[ "$(find "$backup_root" -mindepth 1 -maxdepth 1 ! -name "$manifest_name" -print -quit)" == '' ]] || die 'wrapper or prior rollback data exists; preserve it for manual recovery'
  root_dir "$deployment_root" && root_dir "$candidate_root" || die 'fixed prepared trees are absent or unsafe'
  root_regular "$installed_wrapper" && root_regular "$install_config" || die 'installed packet files are absent or unsafe'
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "${seen[$key]:-}" ]] || die 'installation manifest duplicates a key'
    seen["$key"]=1
    case "$key" in
      schema) [[ "$value" == ai-agent-observability-root-packet-installation-v2 ]] || die 'installation manifest schema is invalid' ;;
      reviewed_id) reviewed_id="$value" ;; deployment_id) deployment_id="$value" ;; candidate_id) candidate_id="$value" ;;
      wrapper_id) wrapper_id="$value" ;; config_id) config_id="$value" ;;
      reviewed_digest) reviewed_digest="$value" ;; deployment_digest) deployment_digest="$value" ;; candidate_digest) candidate_digest="$value" ;;
      wrapper_digest) wrapper_digest="$value" ;; config_digest) config_digest="$value" ;;
      *) die 'installation manifest contains an unknown key' ;;
    esac
  done <"$backup_root/$manifest_name"
  [[ "$reviewed_id" =~ ^[0-9]+:[0-9]+:[0-9a-f]+$ && "$deployment_id" =~ ^[0-9]+:[0-9]+:[0-9a-f]+$ && "$candidate_id" =~ ^[0-9]+:[0-9]+:[0-9a-f]+$ && "$wrapper_id" =~ ^[0-9]+:[0-9]+:[0-9a-f]+$ && "$config_id" =~ ^[0-9]+:[0-9]+:[0-9a-f]+$ && "$reviewed_digest" =~ ^[0-9]+:[0-9]+:[0-9a-f]+$ && "$deployment_digest" =~ ^[0-9a-f]{64}$ && "$candidate_digest" =~ ^[0-9a-f]{64}$ && "$wrapper_digest" =~ ^[0-9a-f]{64}$ && "$config_digest" =~ ^[0-9a-f]{64}$ ]] || die 'installation manifest identities are malformed'
  [[ "$reviewed_id" == "$(path_identity "$reviewed_root")" && "$deployment_id" == "$(path_identity "$deployment_root")" && "$candidate_id" == "$(path_identity "$candidate_root")" && "$wrapper_id" == "$(path_identity "$installed_wrapper")" && "$config_id" == "$(path_identity "$install_config")" ]] || die 'installation object identity changed; preserving data'
  tree_safe "$deployment_root" && tree_safe "$candidate_root" || die 'installation tree became unsafe; preserving data'
  [[ "$reviewed_digest" == "$(path_identity "$reviewed_root")" && "$deployment_digest" == "$(tree_digest "$deployment_root")" && "$candidate_digest" == "$(tree_digest "$candidate_root")" && "$wrapper_digest" == "$(sha256sum "$installed_wrapper" | awk '{print $1}')" && "$config_digest" == "$(sha256sum "$install_config" | awk '{print $1}')" ]] || die 'installation content changed; preserving data'
  printf '%s\n' 'schema=ai-agent-observability-root-packet-rollback-v2' "manifest_sha256=$(sha256sum "$backup_root/$manifest_name" | awk '{print $1}')" 'state=deletion-started' >"$backup_root/$rollback_state_name"
  chmod 0600 "$backup_root/$rollback_state_name"
  rm -f -- "$installed_wrapper" "$install_config"
  rm -rf -- "$candidate_root" "$deployment_root"
  rmdir -- "$(dirname "$candidate_root")" "$reviewed_root"
  rm -f -- "$backup_root/$rollback_state_name"
  rm -f -- "$backup_root/$manifest_name"
  rmdir -- "$backup_root"
  printf '%s\n' 'reviewed root packet installation rolled back; no engine or workload operation was performed'
}

[[ "$mode" == --rollback-install ]] && { rollback_install; exit 0; }

[[ "${READER_IMAGE_ID:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'READER_IMAGE_ID must be the already-local approved immutable image ID'
[[ "${REVIEWED_PACKET_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die 'REVIEWED_PACKET_SHA256 must be the root-recorded installer SHA-256'
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$repo_root" != "$legacy_root" ]] || die 'reviewed source checkout must not be the legacy deployment tree'
[[ -d "$repo_root/.git" || -f "$repo_root/.git" ]] || die 'script must run from the reviewed Git checkout'
packet_actual_sha256="$(sha256sum "$0" | awk '{print $1}')"
[[ "$packet_actual_sha256" == "$REVIEWED_PACKET_SHA256" ]] || die 'installer content does not match the root-recorded review'
[[ -z "$(clean_git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'reviewed source checkout is dirty'
clean_git -C "$repo_root" merge-base --is-ancestor "$expected_head" HEAD || die 'reviewed source checkout does not contain the exact merged candidate'
for path in "$reviewed_root" "$backup_root" "$installed_wrapper" "$install_config"; do trusted_new_parent "$path" || die "destination or ancestor is unsafe: $path"; done

# Reader inspection is a read-only entitlement check. It neither pulls nor
# prints an image; only the exact already-local configured ID is accepted.
if [[ -z "$test_root" ]]; then
  reader_actual="$(env -i PATH="$PATH" /usr/bin/podman image inspect --format '{{.Id}}' "$READER_IMAGE_ID" 2>/dev/null)" || die 'approved reader image is not already local'
  [[ "$reader_actual" == "$READER_IMAGE_ID" ]] || die 'approved reader image identity changed during inspection'
fi

rollback_on_failure() {
  local status=$?
  trap - ERR EXIT
  # Preserve every partial object. Once the journal exists it records created
  # identities; an earlier mkdir failure is still preserved rather than deleted.
  (( status == 0 )) || printf '%s\n' 'installation failed; preserving partial paths and any identity journal for review' >&2
  exit "$status"
}
trap rollback_on_failure ERR EXIT
umask 077
prepare_new_roots || die 'failed to create identity-journaled root paths'
trusted_path "$reviewed_root" && root_dir "$backup_root" && root_regular "$partial_journal" || die 'created root paths or intent journal are unsafe'
clean_git clone --no-local --no-hardlinks --quiet "$repo_root" "$candidate_root"
clean_git -C "$candidate_root" checkout --detach --quiet "$expected_head"
[[ "$(clean_git -C "$candidate_root" rev-parse HEAD)" == "$expected_head" ]] || die 'installed candidate does not match the exact merged commit'
[[ -z "$(clean_git -C "$candidate_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'installed candidate is dirty'

# The legacy source and .env are read from no-follow descriptors once only.
safe_copy_legacy || die 'legacy source copy failed safety checks'
if [[ -n "$test_root" ]]; then
  [[ "${ROOT_PACKET_TEST_BASELINE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die 'hermetic fixture requires an explicit synthetic baseline SHA-256'
  expected_legacy_baseline="$ROOT_PACKET_TEST_BASELINE_SHA256"
else
  expected_legacy_baseline="$baseline_compose_sha256"
fi
[[ "$(sha256sum "$deployment_root/deploy/compose.yaml" | awk '{print $1}')" == "$expected_legacy_baseline" ]] || die 'canonical live source did not preserve the reviewed baseline'
install -o root -g root -m 0755 "$candidate_root/deploy/ai-agent-observability-reviewed-upgrade" "$installed_wrapper"
record_partial_file "$installed_wrapper" || die 'failed to journal created wrapper identity'
cat >"$install_config" <<CONFIG
DEPLOYMENT_ROOT=$deployment_root
CANDIDATE_ROOT=$candidate_root
BACKUP_ROOT=$backup_root
ENGINE_BIN=/usr/bin/podman
READER_IMAGE_ID=$READER_IMAGE_ID
BASELINE_COMPOSE_SHA256=$baseline_compose_sha256
CONFIG
chmod 0600 "$install_config"
record_partial_file "$install_config" || die 'failed to journal created configuration identity'
if [[ -n "$test_root" && "${ROOT_PACKET_TEST_FAIL_AFTER_CONFIG:-}" == 1 ]]; then
  die 'hermetic fixture requested failure after configuration creation'
fi
tree_safe "$deployment_root" && tree_safe "$candidate_root" || die 'installed tree contains an unsafe entry'
printf '%s\n' \
  'schema=ai-agent-observability-root-packet-installation-v2' \
  "reviewed_id=$(path_identity "$reviewed_root")" \
  "deployment_id=$(path_identity "$deployment_root")" \
  "candidate_id=$(path_identity "$candidate_root")" \
  "wrapper_id=$(path_identity "$installed_wrapper")" \
  "config_id=$(path_identity "$install_config")" \
  "reviewed_digest=$(path_identity "$reviewed_root")" \
  "deployment_digest=$(tree_digest "$deployment_root")" \
  "candidate_digest=$(tree_digest "$candidate_root")" \
  "wrapper_digest=$(sha256sum "$installed_wrapper" | awk '{print $1}')" \
  "config_digest=$(sha256sum "$install_config" | awk '{print $1}')" >"$backup_root/$manifest_name"
chmod 0600 "$backup_root/$manifest_name"
rm -f -- "$partial_journal"
trap - ERR EXIT
printf '%s\n' 'reviewed root packet installed; no Compose, service, volume, or source-replacement action was performed'
