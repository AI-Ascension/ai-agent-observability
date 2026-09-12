#!/usr/bin/env bash
# Read-only admission guard for the ClickHouse data and diagnostic filesystems.
#
# Invocation:
#   check-storage.sh --manifest FILE
#
# FILE is an operator-owned tab-delimited key/value manifest. It is parsed as
# data; it is never sourced or evaluated. The required schema is:
#
#   version<TAB>1
#   contract<TAB>block-backed-fixed-v1
#   data.mountpoint<TAB>/absolute/canonical/path
#   data.device<TAB>/dev/canonical-block-device
#   data.uuid<TAB>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   data.fstype<TAB>ext4|xfs|btrfs
#   data.min_free_bytes<TAB>positive-or-zero-decimal
#   data.min_free_inodes<TAB>positive-or-zero-decimal
#   data.reserve_bytes<TAB>positive-or-zero-decimal
#   data.reserve_inodes<TAB>positive-or-zero-decimal
#   data.max_bytes<TAB>positive-decimal
#   data.max_inodes<TAB>positive-decimal
#
# The same ten role fields are required for diagnostic. Admission requires
# available bytes/inodes >= min_free + reserve and filesystem totals <= max.
# The supported contract is a fixed, non-thin filesystem on a physical disk or
# partition, mounted directly at each path. Provisioning that contract is an
# operator dependency; this guard intentionally does not treat a directory,
# bind mount, sparse file, device-mapper/loop device, named volume, or an
# arbitrary filesystem quota as a hard boundary.
set -euo pipefail
export LC_ALL=C

readonly EX_USAGE=64
readonly EX_ADMISSION=69
readonly UINT64_MAX=9223372036854775807
readonly manifest_required_version=1
readonly manifest_required_contract='block-backed-fixed-v1'

usage() {
  printf '%s\n' 'Usage: check-storage.sh --manifest FILE' >&2
}

die_usage() {
  printf 'storage admission configuration error: %s\n' "$1" >&2
  exit "$EX_USAGE"
}

die_admission() {
  printf 'storage admission failed: %s\n' "$1" >&2
  exit "$EX_ADMISSION"
}

[[ $# -eq 2 && $1 == --manifest && -n $2 && $2 != -* ]] || {
  usage
  exit "$EX_USAGE"
}
readonly manifest=$2

for command_name in findmnt realpath stat lsblk df awk; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die_usage "required command is unavailable: $command_name"
done

[[ -f $manifest && -r $manifest && ! -L $manifest ]] ||
  die_usage 'manifest must be a readable regular file (not a symlink)'

# A writable manifest could silently turn a startup guard into a fallback to
# the root filesystem. The file contains no secrets, so ownership is left to
# the operator, but group/other write permission is rejected.
manifest_mode=$(LC_ALL=C stat -c '%a' -- "$manifest" 2>/dev/null) ||
  die_usage 'could not inspect manifest permissions'
[[ $manifest_mode =~ ^[0-7]+$ ]] || die_usage 'manifest mode is not octal'
if (( 8#$manifest_mode & 022 )); then
  die_usage 'manifest must not be group- or world-writable'
fi

declare -A settings=()
known_key() {
  case "$1" in
    version|contract) return 0 ;;
    data.mountpoint|data.device|data.uuid|data.fstype|data.min_free_bytes|\
    data.min_free_inodes|data.reserve_bytes|data.reserve_inodes|data.max_bytes|\
    data.max_inodes) return 0 ;;
    diagnostic.mountpoint|diagnostic.device|diagnostic.uuid|diagnostic.fstype|\
    diagnostic.min_free_bytes|diagnostic.min_free_inodes|diagnostic.reserve_bytes|\
    diagnostic.reserve_inodes|diagnostic.max_bytes|diagnostic.max_inodes) return 0 ;;
    *) return 1 ;;
  esac
}

# Read through one already-open descriptor. This avoids re-opening a path
# after validation and ensures that no shell syntax from the manifest runs.
exec 3<"$manifest"
line_number=0
while IFS= read -r line <&3 || [[ -n $line ]]; do
  ((line_number += 1))
  [[ -z $line ]] && continue
  [[ $line == \#* ]] && continue
  [[ $line != *$'\r' ]] || die_usage "manifest line $line_number has CRLF syntax"
  [[ $line == *$'\t'* ]] || die_usage "manifest line $line_number is not tab-delimited"
  key=${line%%$'\t'*}
  value=${line#*$'\t'}
  [[ $value != *$'\t'* ]] || die_usage "manifest line $line_number has extra columns"
  [[ -n $key ]] || die_usage "manifest line $line_number has an empty key"
  known_key "$key" || die_usage "manifest line $line_number has an unknown key"
  [[ -z ${settings[$key]+present} ]] || die_usage "manifest line $line_number duplicates $key"
  settings["$key"]=$value
done
exec 3<&-

required_key() {
  [[ -n ${settings[$1]+present} ]] || die_usage "manifest is missing $1"
}

required_key version
required_key contract
[[ ${settings[version]} == "$manifest_required_version" ]] ||
  die_usage 'manifest version is unsupported'
[[ ${settings[contract]} == "$manifest_required_contract" ]] ||
  die_usage 'manifest contract is unsupported'

is_uint() {
  local value=$1
  [[ $value =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  ((${#value} < ${#UINT64_MAX})) && return 0
  ((${#value} > ${#UINT64_MAX})) && return 1
  # Equal-length ASCII digit strings compare without overflowing shell arithmetic.
  # shellcheck disable=SC2071
  [[ $value < "$UINT64_MAX" || $value == "$UINT64_MAX" ]]
}

canonical_path() {
  local label=$1 path=$2 canonical
  canonical=$(LC_ALL=C realpath -e -- "$path" 2>/dev/null) ||
    die_admission "$label does not resolve to an existing canonical path"
  [[ -n $canonical && $canonical != *$'\n'* && $canonical != *$'\r'* ]] ||
    die_admission "$label canonical path is invalid"
  printf '%s' "$canonical"
}

validate_mountpoint() {
  local role=$1 path=$2 canonical
  [[ $path == /* && $path != */ && $path != *'//' && $path != *'/./'* &&
    $path != */./ && $path != *'/../'* && $path != */../ ]] ||
    die_usage "$role.mountpoint must be an absolute canonical path"
  [[ $path =~ ^/[A-Za-z0-9._/@+=:-]+$ ]] ||
    die_usage "$role.mountpoint contains unsupported characters"
  canonical=$(canonical_path "$role.mountpoint" "$path")
  [[ $canonical == "$path" ]] ||
    die_admission "$role.mountpoint is not canonical"
}

validate_device() {
  local role=$1 path=$2 canonical device_type
  [[ $path == /dev/* && $path != */ &&
    $path =~ ^/dev/[A-Za-z0-9._/@+=:-]+$ ]] ||
    die_usage "$role.device must be a canonical /dev block path"
  canonical=$(canonical_path "$role.device" "$path")
  [[ $canonical == "$path" ]] ||
    die_admission "$role.device is not canonical"
  device_type=$(LC_ALL=C stat -c '%F' -- "$path" 2>/dev/null) ||
    die_admission "$role.device cannot be inspected"
  [[ $device_type == 'block special file' ]] ||
    die_admission "$role.device is not a block special file"
}

validate_physical_ancestry() {
  local role=$1 device=$2 ancestry block_name block_type extra
  local saw_device=0 saw_disk=0
  ancestry=$(LC_ALL=C lsblk --noheadings --raw --paths --inverse \
    --output NAME,TYPE -- "$device" 2>/dev/null) ||
    die_admission "$role.device physical ancestry cannot be inspected"
  [[ -n $ancestry && $ancestry != *$'\r'* ]] ||
    die_admission "$role.device physical ancestry is empty"
  while IFS=$' \t' read -r block_name block_type extra; do
    [[ -z $block_name && -z $block_type && -z $extra ]] && continue
    [[ -n $block_name && -n $block_type && -z $extra ]] ||
      die_admission "$role.device physical ancestry output is ambiguous"
    [[ $block_name == /dev/* ]] ||
      die_admission "$role.device physical ancestry contains a non-device path"
    case "$block_type" in
      disk) saw_disk=1 ;;
      part) ;;
      *) die_admission "$role.device uses an unsupported block type" ;;
    esac
    [[ $block_name == "$device" ]] && saw_device=1
  done <<<"$ancestry"
  (( saw_device == 1 && saw_disk == 1 )) ||
    die_admission "$role.device is not a physical disk/partition ancestry"
}

validate_uuid() {
  local role=$1 value=$2
  [[ $value =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    die_usage "$role.uuid is not a canonical UUID"
}

validate_fstype() {
  local role=$1 value=$2
  case "$value" in
    ext4|xfs|btrfs) ;;
    *) die_usage "$role.fstype is outside the fixed block-backed contract" ;;
  esac
}

validate_uint_field() {
  local key=$1
  is_uint "${settings[$key]}" || die_usage "$key must be an unsigned decimal integer"
}

sum_uint() {
  local left=$1 right=$2
  (( left <= UINT64_MAX - right )) || return 1
  printf '%s' "$((left + right))"
}

for role in data diagnostic; do
  for field in mountpoint device uuid fstype min_free_bytes min_free_inodes \
    reserve_bytes reserve_inodes max_bytes max_inodes; do
    required_key "$role.$field"
  done
  validate_mountpoint "$role" "${settings[$role.mountpoint]}"
  validate_device "$role" "${settings[$role.device]}"
  validate_physical_ancestry "$role" "${settings[$role.device]}"
  validate_uuid "$role" "${settings[$role.uuid]}"
  validate_fstype "$role" "${settings[$role.fstype]}"
  for field in min_free_bytes min_free_inodes reserve_bytes reserve_inodes max_bytes max_inodes; do
    validate_uint_field "$role.$field"
  done
  (( ${settings[$role.max_bytes]} > 0 && ${settings[$role.max_inodes]} > 0 )) ||
    die_usage "$role ceilings must be positive"
  byte_floor=$(sum_uint "${settings[$role.min_free_bytes]}" "${settings[$role.reserve_bytes]}") ||
    die_usage "$role byte floor overflows the supported integer range"
  inode_floor=$(sum_uint "${settings[$role.min_free_inodes]}" "${settings[$role.reserve_inodes]}") ||
    die_usage "$role inode floor overflows the supported integer range"
  (( ${settings[$role.max_bytes]} >= byte_floor )) ||
    die_usage "$role.max_bytes is smaller than its required free/reserve floor"
  (( ${settings[$role.max_inodes]} >= inode_floor )) ||
    die_usage "$role.max_inodes is smaller than its required free/reserve floor"
done

data_mountpoint=${settings[data.mountpoint]}
diagnostic_mountpoint=${settings[diagnostic.mountpoint]}
[[ $data_mountpoint != "$diagnostic_mountpoint" ]] ||
  die_usage 'data and diagnostic mountpoints must be distinct'
case "$data_mountpoint/" in
  "$diagnostic_mountpoint/"*) die_usage 'data and diagnostic mountpoints must not be nested' ;;
esac
case "$diagnostic_mountpoint/" in
  "$data_mountpoint/"*) die_usage 'data and diagnostic mountpoints must not be nested' ;;
esac

findmnt_field() {
  local path=$1 field=$2 output
  output=$(LC_ALL=C findmnt --noheadings --raw --mountpoint "$path" --output "$field" 2>/dev/null) ||
    die_admission "no exact $field mount record exists for $path"
  [[ -n $output && $output != *$'\n'* && $output != *$'\r'* ]] ||
    die_admission "mount record for $path has an empty or ambiguous $field"
  printf '%s' "$output"
}

findmnt_optional_field() {
  local path=$1 field=$2 output
  output=$(LC_ALL=C findmnt --noheadings --raw --mountpoint "$path" --output "$field" 2>/dev/null) ||
    die_admission "no exact $field mount record exists for $path"
  [[ $output != *$'\n'* && $output != *$'\r'* ]] ||
    die_admission "mount record for $path has an ambiguous $field"
  printf '%s' "$output"
}

root_target=$(findmnt_field / TARGET)
root_source=$(findmnt_field / SOURCE)
root_uuid=$(findmnt_optional_field / UUID)
root_fs_device_id=$(LC_ALL=C stat -c '%d' -- / 2>/dev/null) ||
  die_admission 'root filesystem device identity is unavailable'
is_uint "$root_fs_device_id" || die_admission 'root filesystem device identity is invalid'
[[ $root_target == / && -n $root_source ]] ||
  die_admission 'root mount identity is unavailable'

root_canonical_source=''
case "$root_source" in
  /dev/*)
    root_canonical_source=$(canonical_path root.device "$root_source")
    [[ -n $root_uuid &&
      $root_uuid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
      die_admission 'physical root UUID is unavailable or invalid'
    ;;
  overlay|rootfs|tmpfs|zram*)
    # A virtual root has no block path to alias. Data/diagnostic sources still
    # must be canonical /dev block devices below.
    [[ -z $root_uuid ]] || die_admission 'virtual root unexpectedly has a UUID'
    ;;
  *)
    die_admission 'root source is outside the recognized root identity set'
    ;;
esac

declare -A actual_source_by_role=()
declare -A actual_uuid_by_role=()
declare -A actual_fs_device_id_by_role=()
for role in data diagnostic; do
  mountpoint=${settings[$role.mountpoint]}
  expected_device=${settings[$role.device]}
  expected_uuid=${settings[$role.uuid]}
  expected_fstype=${settings[$role.fstype]}
  actual_target=$(findmnt_field "$mountpoint" TARGET)
  actual_source=$(findmnt_field "$mountpoint" SOURCE)
  actual_fstype=$(findmnt_field "$mountpoint" FSTYPE)
  actual_uuid=$(findmnt_field "$mountpoint" UUID)
  mount_options=$(findmnt_field "$mountpoint" OPTIONS)
  fs_device_id=$(LC_ALL=C stat -c '%d' -- "$mountpoint" 2>/dev/null) ||
    die_admission "$role filesystem device identity is unavailable"
  is_uint "$fs_device_id" || die_admission "$role filesystem device identity is invalid"
  [[ $actual_target == "$mountpoint" ]] ||
    die_admission "$role mount target identity changed"
  [[ $actual_source == /dev/* ]] ||
    die_admission "$role mount source is not a /dev block path"
  actual_canonical_source=$(canonical_path "$role.mount source" "$actual_source")
  [[ $actual_canonical_source == "$expected_device" ]] ||
    die_admission "$role mount source does not match the manifest device"
  [[ $actual_fstype == "$expected_fstype" ]] ||
    die_admission "$role filesystem type does not match the manifest"
  [[ $actual_uuid == "$expected_uuid" ]] ||
    die_admission "$role filesystem UUID does not match the manifest"
  [[ $fs_device_id != "$root_fs_device_id" ]] ||
    die_admission "$role filesystem aliases the root filesystem device identity"
  [[ -z $root_uuid || $actual_uuid != "$root_uuid" ]] ||
    die_admission "$role filesystem UUID aliases the root filesystem"
  case ",$mount_options," in
    *,ro,*) die_admission "$role filesystem is mounted read-only" ;;
    *,rw,*) ;;
    *) die_admission "$role mount options do not prove a read-write filesystem" ;;
  esac
  [[ -z $root_canonical_source || $actual_canonical_source != "$root_canonical_source" ]] ||
    die_admission "$role device aliases the root filesystem"
  actual_source_by_role[$role]=$actual_canonical_source
  actual_uuid_by_role[$role]=$actual_uuid
  actual_fs_device_id_by_role[$role]=$fs_device_id
done

[[ ${actual_source_by_role[data]} != "${actual_source_by_role[diagnostic]}" ]] ||
  die_admission 'data and diagnostic mounts share one block device'
[[ ${actual_uuid_by_role[data]} != "${actual_uuid_by_role[diagnostic]}" ]] ||
  die_admission 'data and diagnostic mounts share one filesystem UUID'
[[ ${actual_fs_device_id_by_role[data]} != "${actual_fs_device_id_by_role[diagnostic]}" ]] ||
  die_admission 'data and diagnostic mounts share one filesystem device identity'

read_df_stats() {
  local role=$1 path=$2 bytes_line inode_line total_bytes avail_bytes total_inodes avail_inodes
  bytes_line=$(LC_ALL=C df -P -B1 -- "$path" 2>/dev/null | awk 'NR == 2 { print $2 " " $4 }') ||
    die_admission "$role byte capacity cannot be inspected"
  [[ $bytes_line =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]] ||
    die_admission "$role byte capacity output is invalid"
  total_bytes=${BASH_REMATCH[1]}
  avail_bytes=${BASH_REMATCH[2]}
  inode_line=$(LC_ALL=C df -P -B1 -i -- "$path" 2>/dev/null | awk 'NR == 2 { print $2 " " $4 }') ||
    die_admission "$role inode capacity cannot be inspected"
  [[ $inode_line =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]] ||
    die_admission "$role inode capacity output is invalid"
  total_inodes=${BASH_REMATCH[1]}
  avail_inodes=${BASH_REMATCH[2]}
  for value_name in total_bytes avail_bytes total_inodes avail_inodes; do
    is_uint "${!value_name}" || die_admission "$role capacity contains an invalid integer"
  done
  (( avail_bytes <= total_bytes && avail_inodes <= total_inodes )) ||
    die_admission "$role capacity reports available space above its total"
  printf '%s\t%s\t%s\t%s' "$total_bytes" "$avail_bytes" "$total_inodes" "$avail_inodes"
}

for role in data diagnostic; do
  stats=$(read_df_stats "$role" "${settings[$role.mountpoint]}")
  IFS=$'\t' read -r total_bytes avail_bytes total_inodes avail_inodes <<<"$stats"
  byte_floor=${settings[$role.min_free_bytes]}
  byte_reserve=${settings[$role.reserve_bytes]}
  inode_floor=${settings[$role.min_free_inodes]}
  inode_reserve=${settings[$role.reserve_inodes]}
  byte_floor=$(sum_uint "$byte_floor" "$byte_reserve") ||
    die_admission "$role byte floor overflows the supported integer range"
  inode_floor=$(sum_uint "$inode_floor" "$inode_reserve") ||
    die_admission "$role inode floor overflows the supported integer range"
  (( total_bytes <= ${settings[$role.max_bytes]} )) ||
    die_admission "$role filesystem total exceeds its declared byte ceiling"
  (( total_inodes <= ${settings[$role.max_inodes]} )) ||
    die_admission "$role filesystem total exceeds its declared inode ceiling"
  (( avail_bytes >= byte_floor )) ||
    die_admission "$role filesystem has less than its required free/reserve bytes"
  (( avail_inodes >= inode_floor )) ||
    die_admission "$role filesystem has less than its required free/reserve inodes"
  printf 'storage admission role=%s mountpoint=%s total_bytes=%s available_bytes=%s total_inodes=%s available_inodes=%s\n' \
    "$role" "${settings[$role.mountpoint]}" "$total_bytes" "$avail_bytes" "$total_inodes" "$avail_inodes"
done

printf '%s\n' 'Storage admission passed for data and diagnostic fixed block-backed filesystems.'
