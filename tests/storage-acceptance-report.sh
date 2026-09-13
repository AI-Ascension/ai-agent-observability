#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
report="$repo_root/deploy/storage/acceptance-report.sh"
# Exit contract: 1 means the manifest was valid but external acceptance gates
# remain open; 64 means usage or manifest input was rejected.
readonly report_check_exit=1
readonly report_usage_exit=64
readonly max_manifest_bytes=65536
[[ -x $report ]] || {
  echo 'Acceptance report must be executable.' >&2
  exit 1
}
bash -n "$report"

# Keep this test effect-free: the report must not invoke a container engine,
# service manager, filesystem tool, or database client.  The command stubs
# below fail closed if an implementation accidentally adds one.
for forbidden in podman docker systemctl findmnt lsblk mount umount mkfs \
  clickhouse jq date timeout; do
  if grep -Eq "(^|[^[:alnum:]_])${forbidden}([^[:alnum:]_]|$)" "$report"; then
    printf 'Acceptance report contains forbidden runtime command: %s\n' "$forbidden" >&2
    exit 1
  fi
done
if grep -Eq '(^|[^[:alnum:]_])(start|stop|restart|reload|kill|rm|fallocate)([^[:alnum:]_]|$)' \
  "$report"; then
  echo 'Acceptance report contains a mutation verb.' >&2
  exit 1
fi

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
manifest="$test_root/storage.tsv"
cat >"$manifest" <<'FIXTURE'
version	1
contract	block-backed-fixed-v1
data.mountpoint	/srv/observability-data
data.device	/dev/sda1
data.uuid	11111111-1111-1111-1111-111111111111
data.fstype	ext4
data.min_free_bytes	0
data.min_free_inodes	0
data.reserve_bytes	1048576
data.reserve_inodes	100
data.max_bytes	1073741824
data.max_inodes	100000
diagnostic.mountpoint	/srv/observability-diagnostic
diagnostic.device	/dev/sda2
diagnostic.uuid	22222222-2222-2222-2222-222222222222
diagnostic.fstype	ext4
diagnostic.min_free_bytes	0
diagnostic.min_free_inodes	0
diagnostic.reserve_bytes	1048576
diagnostic.reserve_inodes	100
diagnostic.max_bytes	67108864
diagnostic.max_inodes	10000
FIXTURE
chmod 600 "$manifest"

mkdir "$test_root/bin"
marker="$test_root/forbidden-command-used"
export marker
for forbidden in podman docker systemctl findmnt lsblk mount umount mkfs \
  clickhouse jq date timeout; do
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$0" >>"$marker"' \
    'exit 99' >"$test_root/bin/$forbidden"
  chmod 700 "$test_root/bin/$forbidden"
done

status=0
PATH="$test_root/bin:$PATH" "$report" --manifest "$manifest" \
  >"$test_root/report.one" 2>"$test_root/report.one.error" || status=$?
[[ $status == "$report_check_exit" ]] || {
  printf 'Valid report returned %s, expected %s.\n' "$status" "$report_check_exit" >&2
  cat "$test_root/report.one.error" >&2
  exit 1
}
[[ ! -e $marker ]] || {
  echo 'Acceptance report invoked a forbidden runtime command.' >&2
  exit 1
}

# The report must validate and parse one captured manifest snapshot.  Delegate
# to the real od so the scan succeeds, then mutate only the original path.
# A separate-read implementation reopens that path and rejects the appended
# unknown key; a one-snapshot implementation keeps the deterministic report.
real_od=$(command -v od) || {
  echo 'od is required for the snapshot mutation regression.' >&2
  exit 1
}
mutation_manifest="$test_root/mutation.tsv"
cp "$manifest" "$mutation_manifest"
mutation_marker="$test_root/od-mutated"
mkdir "$test_root/mutation-bin"
cat >"$test_root/mutation-bin/od" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
"${REAL_OD:?}" "$@"
printf '%s\t%s\n' unknown.key mutated >>"${MUTATION_MANIFEST:?}"
: >"${MUTATION_MARKER:?}"
STUB
chmod 700 "$test_root/mutation-bin/od"
status=0
REAL_OD="$real_od" MUTATION_MANIFEST="$mutation_manifest" \
  MUTATION_MARKER="$mutation_marker" PATH="$test_root/mutation-bin:$PATH" \
  "$report" --manifest "$mutation_manifest" \
  >"$test_root/report.mutation" 2>"$test_root/report.mutation.error" || status=$?
[[ $status == "$report_check_exit" ]] || {
  printf 'Snapshot report returned %s, expected %s after source mutation.\n' \
    "$status" "$report_check_exit" >&2
  cat "$test_root/report.mutation.error" >&2
  exit 1
}
[[ -e $mutation_marker ]] || {
  echo 'od mutation stub was not invoked.' >&2
  exit 1
}
grep -Fqx $'unknown.key\tmutated' "$mutation_manifest" || {
  echo 'od mutation stub did not append the manifest mutation.' >&2
  exit 1
}
cmp "$test_root/report.one" "$test_root/report.mutation"
[[ ! -s "$test_root/report.mutation.error" ]]

# Repeat the snapshot regression with a raw-byte mutation.  The wrapper scans
# the captured snapshot first, then overwrites byte 1 of the original path
# with NUL.  A separate-read parser sees the NUL and rejects the source;
# parsing the one captured snapshot preserves the deterministic report.
nul_mutation_manifest="$test_root/nul-mutation.tsv"
cp "$manifest" "$nul_mutation_manifest"
nul_mutation_marker="$test_root/od-nul-mutated"
mkdir "$test_root/nul-mutation-bin"
cat >"$test_root/nul-mutation-bin/od" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
"${REAL_OD:?}" "$@"
printf '\0' | dd of="${NUL_MUTATION_MANIFEST:?}" bs=1 count=1 conv=notrunc 2>/dev/null
: >"${NUL_MUTATION_MARKER:?}"
STUB
chmod 700 "$test_root/nul-mutation-bin/od"
status=0
REAL_OD="$real_od" NUL_MUTATION_MANIFEST="$nul_mutation_manifest" \
  NUL_MUTATION_MARKER="$nul_mutation_marker" PATH="$test_root/nul-mutation-bin:$PATH" \
  "$report" --manifest "$nul_mutation_manifest" \
  >"$test_root/report.nul-mutation" 2>"$test_root/report.nul-mutation.error" || status=$?
[[ $status == "$report_check_exit" ]] || {
  printf 'NUL snapshot report returned %s, expected %s after source mutation.\n' \
    "$status" "$report_check_exit" >&2
  cat "$test_root/report.nul-mutation.error" >&2
  exit 1
}
[[ -e $nul_mutation_marker ]] || {
  echo 'od NUL mutation stub was not invoked.' >&2
  exit 1
}
nul_mutation_first_byte=$(LC_ALL=C od -An -tx1 -N1 "$nul_mutation_manifest")
nul_mutation_first_byte=${nul_mutation_first_byte//[[:space:]]/}
[[ $nul_mutation_first_byte == 00 ]] || {
  printf 'NUL mutation source begins with %s, expected 00.\n' \
    "$nul_mutation_first_byte" >&2
  exit 1
}
cmp "$test_root/report.one" "$test_root/report.nul-mutation"
[[ ! -s "$test_root/report.nul-mutation.error" ]]

status=0
PATH="$test_root/bin:$PATH" "$report" --manifest "$manifest" \
  >"$test_root/report.two" 2>"$test_root/report.two.error" || status=$?
[[ $status == "$report_check_exit" ]] || exit 1
cmp "$test_root/report.one" "$test_root/report.two"
[[ ! -s "$test_root/report.one.error" && ! -s "$test_root/report.two.error" ]]

for expected in \
  report_version=storage-acceptance-v1 \
  observed_at=unrecorded \
  manifest_input=confirmed \
  manifest_admission=unverified \
  repository_checks=confirmed \
  privileged_host_inspection=unverified \
  immutable_inputs_budgets=unverified \
  compose_startup=unverified \
  diagnostic_containment=unverified \
  pressure_lifecycle=unverified \
  migration=unverified \
  backup_rollback=unverified \
  sustained_load=unverified \
  reboot_persistence=unverified \
  external_acceptance=unverified \
  production_acceptance=unverified \
  result=unverified; do
  grep -Fxq "$expected" "$test_root/report.one" || {
    printf 'Report is missing deterministic field: %s\n' "$expected" >&2
    exit 1
  }
done
if grep -Eq '^(result|external_acceptance|production_acceptance)=confirmed$' \
  "$test_root/report.one"; then
  echo 'Acceptance report claimed production acceptance.' >&2
  exit 1
fi

printf '%s\n' \
  'version	1' \
  'contract	block-backed-fixed-v1' >"$test_root/malformed.tsv"
status=0
"$report" --manifest "$test_root/malformed.tsv" \
  >"$test_root/malformed.out" 2>"$test_root/malformed.error" || status=$?
[[ $status == "$report_usage_exit" &&
  ! -s "$test_root/malformed.out" && -s "$test_root/malformed.error" ]] || {
  echo 'Malformed manifest did not fail closed.' >&2
  exit 1
}

cp "$manifest" "$test_root/nul.tsv"
printf '\0' >>"$test_root/nul.tsv"
status=0
"$report" --manifest "$test_root/nul.tsv" \
  >"$test_root/nul.out" 2>"$test_root/nul.error" || status=$?
[[ $status == "$report_usage_exit" &&
  ! -s "$test_root/nul.out" && -s "$test_root/nul.error" ]] || {
  echo 'NUL-containing manifest did not fail closed.' >&2
  exit 1
}

status=0
"$report" --manifest "$test_root/missing.tsv" \
  >"$test_root/missing.out" 2>"$test_root/missing.error" || status=$?
[[ $status == "$report_usage_exit" && ! -s "$test_root/missing.out" ]] || {
  echo 'Missing manifest did not fail closed.' >&2
  exit 1
}

# Build a genuinely oversized manifest (>65,536 bytes) without violating the
# separate 2,048-byte line or 128-line limits.  This proves the global byte
# cap itself rejects an otherwise parseable input.
{
  cat "$manifest"
  for ((padding_line = 0; padding_line < 32; padding_line += 1)); do
    printf '#%2046s\n' ''
  done
} >"$test_root/oversized.tsv"
oversized_bytes=$(wc -c <"$test_root/oversized.tsv")
oversized_bytes=${oversized_bytes//[[:space:]]/}
[[ $oversized_bytes =~ ^[0-9]+$ && $oversized_bytes -gt $max_manifest_bytes ]] || {
  printf 'Oversized fixture measured %s bytes, expected more than %s.\n' \
    "$oversized_bytes" "$max_manifest_bytes" >&2
  exit 1
}
status=0
"$report" --manifest "$test_root/oversized.tsv" \
  >"$test_root/oversized.out" 2>"$test_root/oversized.error" || status=$?
[[ $status == "$report_usage_exit" &&
  ! -s "$test_root/oversized.out" && -s "$test_root/oversized.error" ]] || {
  echo 'Oversized manifest did not fail closed.' >&2
  exit 1
}

sed 's/^data.max_bytes.*/data.max_bytes	9223372036854775808/' \
  "$manifest" >"$test_root/overflow.tsv"
status=0
"$report" --manifest "$test_root/overflow.tsv" \
  >"$test_root/overflow.out" 2>"$test_root/overflow.error" || status=$?
[[ $status == "$report_usage_exit" &&
  ! -s "$test_root/overflow.out" && -s "$test_root/overflow.error" ]] || {
  echo 'Overflowing numeric manifest value did not fail closed.' >&2
  exit 1
}

status=0
"$report" --manifest "$test_root/../storage.tsv" \
  >"$test_root/noncanonical.out" 2>"$test_root/noncanonical.error" || status=$?
[[ $status == "$report_usage_exit" &&
  ! -s "$test_root/noncanonical.out" && -s "$test_root/noncanonical.error" ]] || {
  echo 'Noncanonical manifest path did not fail closed.' >&2
  exit 1
}

printf '%s\n' 'Storage acceptance report is deterministic, bounded, effect-free, and keeps external gates unverified.'
