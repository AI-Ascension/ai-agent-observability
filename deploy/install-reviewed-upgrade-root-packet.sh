#!/bin/bash -p
set -Eeuo pipefail

# Root-only, bounded installation of the reviewed-upgrade packet. It prepares
# fixed paths only; it never invokes Compose, starts/stops a service, pulls an
# image, or materializes the candidate into the canonical live tree.
readonly expected_head='c309c8e532574754609d9491f0a10be584f83a83'
readonly legacy_root='/home/completetrain/ai-agent-observability'
readonly reviewed_root='/srv/ai-agent-observability-reviewed'
readonly deployment_root="$reviewed_root/live"
readonly candidate_root="$reviewed_root/candidate/$expected_head"
readonly backup_root='/var/backups/ai-agent-observability-reviewed-upgrade'
readonly installed_wrapper='/usr/local/sbin/ai-agent-observability-reviewed-upgrade'
readonly install_config='/etc/ai-agent-observability-reviewed-upgrade.conf'
readonly manifest_name='.root-packet-installation-v1'
readonly partial_manifest_name='.root-packet-installation-partial-v2'
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
  IFS=/ read -r -a components <<<"${input#/}"
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
tree_safe() {
  local unsafe
  unsafe="$(find "$1" \( -type l -o \( ! -type d -a ! -type f \) -o ! -user root -o -perm /022 \) -print -quit)" || return 1
  [[ -z "$unsafe" ]]
}
tree_digest() { tar --sort=name --format=posix --numeric-owner -C "$(dirname -- "$1")" -cf - "$(basename -- "$1")" | sha256sum | awk '{print $1}'; }
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
            while data := os.read(src, 1048576):
                view = memoryview(data)
                while view: view = view[os.write(dst, view):]
            os.fchmod(dst, mode & ~0o022)
        finally: os.close(dst)
    finally: os.close(src)
def tree(source_fd, destination_fd, relative=()):
    with os.scandir(os.dup(source_fd)) as entries:
        for entry in entries:
            child = relative + (entry.name,)
            if child == ("deploy", ".env"): continue
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
reader_actual="$(env -i PATH="$PATH" /usr/bin/podman image inspect --format '{{.Id}}' "$READER_IMAGE_ID" 2>/dev/null)" || die 'approved reader image is not already local'
[[ "$reader_actual" == "$READER_IMAGE_ID" ]] || die 'approved reader image identity changed during inspection'

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
install -d -o root -g root -m 0700 -- "$reviewed_root" "$(dirname "$candidate_root")" "$deployment_root" "$backup_root"
trusted_path "$reviewed_root" && root_dir "$backup_root" || die 'created root paths are unsafe'
printf '%s\n' 'schema=ai-agent-observability-root-packet-partial-v2' "reviewed_id=$(path_identity "$reviewed_root")" "deployment_id=$(path_identity "$deployment_root")" "candidate_parent_id=$(path_identity "$(dirname "$candidate_root")")" >"$backup_root/$partial_manifest_name"
chmod 0600 "$backup_root/$partial_manifest_name"
clean_git clone --no-local --no-hardlinks --quiet "$repo_root" "$candidate_root"
clean_git -C "$candidate_root" checkout --detach --quiet "$expected_head"
[[ "$(clean_git -C "$candidate_root" rev-parse HEAD)" == "$expected_head" ]] || die 'installed candidate does not match the exact merged commit'
[[ -z "$(clean_git -C "$candidate_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'installed candidate is dirty'

# The legacy source and .env are read from no-follow descriptors once only.
safe_copy_legacy || die 'legacy source copy failed safety checks'
[[ "$(sha256sum "$deployment_root/deploy/compose.yaml" | awk '{print $1}')" == "$baseline_compose_sha256" ]] || die 'canonical live source did not preserve the reviewed baseline'
install -o root -g root -m 0755 "$candidate_root/deploy/ai-agent-observability-reviewed-upgrade" "$installed_wrapper"
cat >"$install_config" <<CONFIG
DEPLOYMENT_ROOT=$deployment_root
CANDIDATE_ROOT=$candidate_root
BACKUP_ROOT=$backup_root
ENGINE_BIN=/usr/bin/podman
READER_IMAGE_ID=$READER_IMAGE_ID
BASELINE_COMPOSE_SHA256=$baseline_compose_sha256
CONFIG
chmod 0600 "$install_config"
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
rm -f -- "$backup_root/$partial_manifest_name"
trap - ERR EXIT
printf '%s\n' 'reviewed root packet installed; no Compose, service, volume, or source-replacement action was performed'
