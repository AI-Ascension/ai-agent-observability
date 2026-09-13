#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin"
cp "$repo_root/tests/fixtures/storage-probe" "$fixture_dir/bin/probe"
chmod 755 "$fixture_dir/bin/probe"
for name in stat findmnt realpath lsblk df; do ln -s probe "$fixture_dir/bin/$name"; done
export PATH="$fixture_dir/bin:$PATH"
export TEST_MANIFEST="$fixture_dir/manifest.tsv"
{
  printf 'version\t1\ncontract\tblock-backed-fixed-v1\n'
  for role in data diagnostic; do
    if [[ "$role" == data ]]; then path=/srv/data; device=/dev/sda1; uuid=11111111-1111-1111-1111-111111111111
    else path=/srv/logs; device=/dev/sda2; uuid=22222222-2222-2222-2222-222222222222; fi
    printf '%s.mountpoint\t%s\n%s.device\t%s\n%s.uuid\t%s\n' "$role" "$path" "$role" "$device" "$role" "$uuid"
    for pair in fstype:ext4 min_free_bytes:100000 min_free_inodes:100 reserve_bytes:100000 reserve_inodes:100 max_bytes:1000000 max_inodes:1000; do
      printf '%s.%s\t%s\n' "$role" "${pair%%:*}" "${pair#*:}"
    done
  done
} >"$TEST_MANIFEST"
chmod 600 "$TEST_MANIFEST"
check() { bash "$repo_root/deploy/storage/check-storage.sh" --manifest "$TEST_MANIFEST"; }
FAULT=healthy check >/dev/null
count=1
for fault in missing replaced wrong_uuid read_only root_alias shared_fs thin loop full inodes negative ceiling overflow symlink; do
  status=0
  FAULT=$fault check >"$fixture_dir/output" 2>&1 || status=$?
  [[ "$status" == 69 ]] || { echo "Expected admission refusal for $fault, got $status" >&2; cat "$fixture_dir/output" >&2; exit 1; }
  count=$((count+1))
done
cp "$TEST_MANIFEST" "$fixture_dir/original"
printf 'data.min_free_bytes\t0\n' >>"$TEST_MANIFEST"
status=0; check >/dev/null 2>&1 || status=$?
[[ "$status" == 64 ]]; count=$((count+1))
cp "$fixture_dir/original" "$TEST_MANIFEST"
chmod 666 "$TEST_MANIFEST"
status=0; check >/dev/null 2>&1 || status=$?
[[ "$status" == 64 ]]; count=$((count+1))
chmod 600 "$TEST_MANIFEST"
sed 's/data.min_free_bytes.*/data.min_free_bytes\t9999999999999999999999999/' "$fixture_dir/original" >"$TEST_MANIFEST"
status=0; check >/dev/null 2>&1 || status=$?
[[ "$status" == 64 ]]; count=$((count+1))
printf 'Storage admission: %s command-fixture cases passed (not live mount/quota evidence).\n' "$count"
