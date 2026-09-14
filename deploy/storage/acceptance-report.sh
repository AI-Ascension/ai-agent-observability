#!/usr/bin/env bash
# Emit the repository-side storage acceptance checklist.
#
# This command is deliberately effect-free.  It validates only the supplied
# manifest's bounded syntax; privileged host inspection, runtime observation,
# migration and production acceptance remain external gates.  A syntactically
# valid input therefore still exits nonzero so an unverified report cannot be
# mistaken for acceptance.
set -euo pipefail
export LC_ALL=C

readonly EX_USAGE=64
readonly EX_CHECK=1
readonly max_manifest_bytes=65536
readonly max_manifest_lines=128
readonly max_manifest_line_bytes=2048
readonly manifest_required_version=1
readonly manifest_required_contract='block-backed-fixed-v1'
readonly max_manifest_uint=9223372036854775807

usage() {
  printf '%s\n' 'Usage: acceptance-report.sh --manifest ABSOLUTE_MANIFEST' >&2
}

die_usage() {
  printf 'acceptance report input error: %s\n' "$1" >&2
  exit "$EX_USAGE"
}

# Reject any non-canonical path production: a duplicate slash, or a `.`/`..`
# component anywhere, including when it is the final component.  The report has
# no realpath fallback, so this syntax gate is the only repository-side defence
# against a value that the privileged check-storage.sh gate would later reject.
is_canonical_components() {
  local value=$1
  [[ $value != *'//'* && $value != *'/./'* && $value != */./ &&
    $value != *'/../'* && $value != */../ &&
    $value != *'/.' && $value != *'/..' ]]
}

[[ $# -eq 2 && $1 == --manifest && -n $2 && $2 == /* && $2 != -* ]] || {
  usage
  exit "$EX_USAGE"
}
readonly manifest=$2
[[ $manifest != *$'\n'* && $manifest != *$'\r'* ]] ||
  die_usage 'manifest path contains a line separator'
[[ $manifest != */ && $manifest =~ ^/[A-Za-z0-9._/@+=:-]+$ ]] &&
  is_canonical_components "$manifest" ||
  die_usage 'manifest path contains unsupported characters'
[[ -f $manifest && ! -L $manifest && -r $manifest ]] ||
  die_usage 'manifest must be a readable regular file (not a symlink)'
command -v od >/dev/null 2>&1 ||
  die_usage 'od is required to inspect manifest bytes'
command -v dd >/dev/null 2>&1 ||
  die_usage 'dd is required to snapshot manifest bytes'
command -v mktemp >/dev/null 2>&1 ||
  die_usage 'mktemp is required to snapshot manifest bytes'
command -v wc >/dev/null 2>&1 ||
  die_usage 'wc is required to bound manifest bytes'

# Read the original path once into a raw-byte snapshot.  A shell variable is
# not suitable here because Bash cannot preserve NUL bytes in command
# substitution; the temporary file keeps every byte unchanged.  Reading one
# block that is exactly one byte larger than the admitted limit lets the
# snapshot distinguish a 65,537th byte without ever consuming an unbounded
# stream.
manifest_snapshot=''
cleanup_snapshot() {
  [[ -z $manifest_snapshot ]] || unlink "$manifest_snapshot" || :
}
trap cleanup_snapshot EXIT
manifest_snapshot=$(mktemp "${TMPDIR:-/tmp}/acceptance-report.XXXXXX") ||
  die_usage 'manifest snapshot cannot be created'
readonly manifest_snapshot

exec 3<"$manifest" || die_usage 'manifest cannot be opened'
if ! dd bs=65537 count=1 <&3 >"$manifest_snapshot" 2>/dev/null; then
  exec 3<&-
  die_usage 'manifest bytes cannot be read'
fi
exec 3<&-

snapshot_size=$(wc -c <"$manifest_snapshot") ||
  die_usage 'manifest snapshot size cannot be inspected'
snapshot_size=${snapshot_size//[[:space:]]/}
[[ $snapshot_size =~ ^[0-9]+$ ]] ||
  die_usage 'manifest snapshot size is invalid'
(( snapshot_size <= max_manifest_bytes )) ||
  die_usage "manifest exceeds ${max_manifest_bytes} bytes"

# Keep both sides' statuses.  With pipefail, an od failure followed by awk's
# expected status 1 ("no NUL") would otherwise look like a successful scan.
nul_scan_pipeline=()
if LC_ALL=C od -An -tx1 "$manifest_snapshot" |
  awk '{ for (field_index = 1; field_index <= NF; field_index++)
           if ($field_index == "00") found = 1 }
       END { exit(found ? 0 : 1) }'; then
  nul_scan_pipeline=("${PIPESTATUS[@]}")
else
  nul_scan_pipeline=("${PIPESTATUS[@]}")
fi
(( nul_scan_pipeline[0] == 0 )) ||
  die_usage 'manifest bytes cannot be inspected'
case "${nul_scan_pipeline[1]}" in
  0) die_usage 'manifest contains a NUL byte' ;;
  1) ;;
  *) die_usage 'manifest bytes cannot be inspected' ;;
esac

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

exec 3<"$manifest_snapshot" || die_usage 'manifest snapshot cannot be opened'
line_number=0
while IFS= read -r line <&3 || [[ -n $line ]]; do
  ((line_number += 1))
  (( line_number <= max_manifest_lines )) ||
    die_usage "manifest exceeds ${max_manifest_lines} lines"
  (( ${#line} <= max_manifest_line_bytes )) ||
    die_usage "manifest line ${line_number} exceeds ${max_manifest_line_bytes} bytes"
  [[ -z $line ]] && continue
  [[ $line == \#* ]] && continue
  [[ $line != *$'\r' ]] ||
    die_usage "manifest line ${line_number} has CRLF syntax"
  [[ $line == *$'\t'* ]] ||
    die_usage "manifest line ${line_number} is not tab-delimited"
  key=${line%%$'\t'*}
  value=${line#*$'\t'}
  [[ $value != *$'\t'* ]] ||
    die_usage "manifest line ${line_number} has extra columns"
  [[ -n $key && $key =~ ^[a-z][a-z0-9._]*$ ]] ||
    die_usage "manifest line ${line_number} has an invalid key"
  known_key "$key" ||
    die_usage "manifest line ${line_number} has an unknown key"
  [[ -n $value && $value != *$'\r'* && $value != *$'\n'* ]] ||
    die_usage "manifest line ${line_number} has an empty or unsafe value"
  [[ -z ${settings[$key]+present} ]] ||
    die_usage "manifest line ${line_number} duplicates $key"
  settings["$key"]=$value
done
exec 3<&-

required_key() {
  local key=$1
  [[ -n ${settings[$key]+present} && -n ${settings[$key]} ]] ||
    die_usage "manifest is missing $key"
}

is_uint() {
  local value=$1
  [[ $value =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  if (( ${#value} < ${#max_manifest_uint} )); then
    return 0
  fi
  (( ${#value} == ${#max_manifest_uint} )) || return 1
  # shellcheck disable=SC2071 # equal-length decimal strings need lexical ordering.
  [[ $value < "$max_manifest_uint" || $value == "$max_manifest_uint" ]]
}

is_path_syntax() {
  local value=$1
  [[ $value == /* && $value != */ && $value =~ ^/[A-Za-z0-9._/@+=:-]+$ ]] &&
    is_canonical_components "$value"
}

is_device_syntax() {
  local value=$1
  [[ $value == /dev/* && $value != */ &&
    $value =~ ^/dev/[A-Za-z0-9._/@+=:-]+$ ]] &&
    is_canonical_components "$value"
}

is_uuid() {
  [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

for key in \
  version contract \
  data.mountpoint data.device data.uuid data.fstype \
  data.min_free_bytes data.min_free_inodes data.reserve_bytes data.reserve_inodes \
  data.max_bytes data.max_inodes \
  diagnostic.mountpoint diagnostic.device diagnostic.uuid diagnostic.fstype \
  diagnostic.min_free_bytes diagnostic.min_free_inodes diagnostic.reserve_bytes \
  diagnostic.reserve_inodes diagnostic.max_bytes diagnostic.max_inodes; do
  required_key "$key"
done

[[ ${settings[version]} == "$manifest_required_version" ]] ||
  die_usage 'manifest version is unsupported'
[[ ${settings[contract]} == "$manifest_required_contract" ]] ||
  die_usage 'manifest contract is unsupported'

for role in data diagnostic; do
  mountpoint=${settings[$role.mountpoint]}
  device=${settings[$role.device]}
  uuid=${settings[$role.uuid]}
  fstype=${settings[$role.fstype]}
  is_path_syntax "$mountpoint" ||
    die_usage "$role.mountpoint is not a canonical path-shaped value"
  is_device_syntax "$device" ||
    die_usage "$role.device is not a canonical device-shaped value"
  is_uuid "$uuid" || die_usage "$role.uuid is not a canonical UUID"
  case "$fstype" in
    ext4|xfs|btrfs) ;;
    *) die_usage "$role.fstype is unsupported" ;;
  esac
  for field in min_free_bytes min_free_inodes reserve_bytes reserve_inodes \
    max_bytes max_inodes; do
    is_uint "${settings[$role.$field]}" ||
      die_usage "$role.$field is not an unsigned decimal integer"
  done
  [[ ${settings[$role.max_bytes]} =~ ^[1-9][0-9]*$ &&
    ${settings[$role.max_inodes]} =~ ^[1-9][0-9]*$ ]] ||
    die_usage "$role ceilings must be positive"
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

report() {
  local key=$1 value=$2
  [[ $key =~ ^[a-z][a-z0-9_]*$ ]] ||
    die_usage "invalid report key: $key"
  [[ $value =~ ^[A-Za-z0-9._:/+-]+$ ]] ||
    die_usage "invalid report value for $key"
  printf '%s=%s\n' "$key" "$value"
}

# Keep this field order stable: operators can diff two reports without
# timestamps or host identifiers, and every external gate is visibly open.
report report_version storage-acceptance-v1
report observed_at unrecorded
report manifest_input confirmed
report manifest_admission unverified
report repository_checks confirmed
report repository_check_scope manifest-schema-only
report privileged_host_inspection unverified
report container_name unverified
report timer_name unverified
report storage_service_name unverified
report runtime_container unverified
report container_id unverified
report image_id unverified
report runtime_state unverified
report health_state unverified
report readonly_root unverified
report restart_policy unverified
report log_driver unverified
report log_path_match unverified
report log_size_bytes unverified
report bind_mounts unverified
report clickhouse_logger unverified
report timer_enabled unverified
report timer_state unverified
report storage_service_enabled unverified
report diagnostic_route unverified
report immutable_inputs_budgets unverified
report compose_startup unverified
report diagnostic_containment unverified
report pressure_lifecycle unverified
report migration unverified
report backup_rollback unverified
report sustained_load unverified
report reboot_persistence unverified
report alerts unverified
report external_acceptance unverified
report production_acceptance unverified
report result unverified

# The report is useful as a checklist, never as a production gate.
exit "$EX_CHECK"
