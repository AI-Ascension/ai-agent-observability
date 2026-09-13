#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
report="$repo_root/deploy/storage/acceptance-report.sh"
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
[[ $status == 1 ]] || {
  printf 'Valid report returned %s, expected 1.\n' "$status" >&2
  cat "$test_root/report.one.error" >&2
  exit 1
}
[[ ! -e $marker ]] || {
  echo 'Acceptance report invoked a forbidden runtime command.' >&2
  exit 1
}

status=0
PATH="$test_root/bin:$PATH" "$report" --manifest "$manifest" \
  >"$test_root/report.two" 2>"$test_root/report.two.error" || status=$?
[[ $status == 1 ]] || exit 1
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
[[ $status == 64 && ! -s "$test_root/malformed.out" && -s "$test_root/malformed.error" ]] || {
  echo 'Malformed manifest did not fail closed.' >&2
  exit 1
}

cp "$manifest" "$test_root/nul.tsv"
printf '\0' >>"$test_root/nul.tsv"
status=0
"$report" --manifest "$test_root/nul.tsv" \
  >"$test_root/nul.out" 2>"$test_root/nul.error" || status=$?
[[ $status == 64 && ! -s "$test_root/nul.out" && -s "$test_root/nul.error" ]] || {
  echo 'NUL-containing manifest did not fail closed.' >&2
  exit 1
}

status=0
"$report" --manifest "$test_root/missing.tsv" \
  >"$test_root/missing.out" 2>"$test_root/missing.error" || status=$?
[[ $status == 64 && ! -s "$test_root/missing.out" ]] || {
  echo 'Missing manifest did not fail closed.' >&2
  exit 1
}

printf '%*s\n' 65537 '' >"$test_root/oversized.tsv"
status=0
"$report" --manifest "$test_root/oversized.tsv" \
  >"$test_root/oversized.out" 2>"$test_root/oversized.error" || status=$?
[[ $status == 64 && ! -s "$test_root/oversized.out" && -s "$test_root/oversized.error" ]] || {
  echo 'Oversized manifest did not fail closed.' >&2
  exit 1
}

sed 's/^data.max_bytes.*/data.max_bytes	9223372036854775808/' \
  "$manifest" >"$test_root/overflow.tsv"
status=0
"$report" --manifest "$test_root/overflow.tsv" \
  >"$test_root/overflow.out" 2>"$test_root/overflow.error" || status=$?
[[ $status == 64 && ! -s "$test_root/overflow.out" && -s "$test_root/overflow.error" ]] || {
  echo 'Overflowing numeric manifest value did not fail closed.' >&2
  exit 1
}

status=0
"$report" --manifest "$test_root/../storage.tsv" \
  >"$test_root/noncanonical.out" 2>"$test_root/noncanonical.error" || status=$?
[[ $status == 64 && ! -s "$test_root/noncanonical.out" && -s "$test_root/noncanonical.error" ]] || {
  echo 'Noncanonical manifest path did not fail closed.' >&2
  exit 1
}

printf '%s\n' 'Storage acceptance report is deterministic, bounded, effect-free, and keeps external gates unverified.'
