#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/deploy/install-reviewed-upgrade-root-packet.sh"

bash -n "$installer"
grep -Fq "readonly expected_head='7c5f3eab18446dea7f1eeafb8427cbe574c1d199'" "$installer"
grep -Fq 'REVIEWED_PACKET_SHA256 must be the root-recorded installer SHA-256' "$installer"
grep -Fq 'installer content does not match the root-recorded review' "$installer"
grep -Fq -- '--install | --rollback-install' "$installer"
grep -Fq 'installation object identity changed; preserving data' "$installer"
grep -Fq 'installation content changed; preserving data' "$installer"
! grep -Eq 'compose (up|down)|systemctl (start|stop|restart)|container (start|stop)|volume rm|image (pull|rm)' "$installer"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
awk '/^safe_copy_legacy\(\)/ { in_copy=1 } in_copy && /^import os, stat, sys$/ { emit=1 } emit { print } emit && /^PY$/ { exit }' \
  "$installer" | sed '$d' >"$test_root/copy.py"
mkdir -p "$test_root/source/deploy" "$test_root/destination"
printf '%s\n' 'baseline' >"$test_root/source/deploy/compose.yaml"
printf '%s\n' 'protected' >"$test_root/source/deploy/.env"
printf '%s\n' 'ordinary' >"$test_root/source/file"
python3 -I "$test_root/copy.py" "$test_root/source" "$test_root/destination"
cmp "$test_root/source/deploy/.env" "$test_root/destination/deploy/.env"
cmp "$test_root/source/file" "$test_root/destination/file"

mkdir -p "$test_root/symlink-source/deploy" "$test_root/symlink-destination"
printf '%s\n' 'protected' >"$test_root/symlink-source/deploy/.env"
ln -s /etc/passwd "$test_root/symlink-source/link"
if python3 -I "$test_root/copy.py" "$test_root/symlink-source" "$test_root/symlink-destination" >/dev/null 2>&1; then
  printf '%s\n' 'legacy copy accepted a symlink' >&2; exit 1
fi

mkdir -p "$test_root/fifo-source/deploy" "$test_root/fifo-destination"
printf '%s\n' 'protected' >"$test_root/fifo-source/deploy/.env"
mkfifo "$test_root/fifo-source/fifo"
set +e
timeout 2s python3 -I "$test_root/copy.py" "$test_root/fifo-source" "$test_root/fifo-destination" >/dev/null 2>&1
fifo_status=$?
set -e
if [[ "$fifo_status" -eq 0 ]]; then
  printf '%s\n' 'legacy copy accepted a FIFO' >&2; exit 1
fi
if [[ "$fifo_status" -eq 124 ]]; then
  printf '%s\n' 'legacy copy blocked on a FIFO instead of refusing it' >&2; exit 1
fi

mkdir -p "$test_root/mutate-source/deploy" "$test_root/mutate-destination"
printf '%s\n' 'protected' >"$test_root/mutate-source/deploy/.env"
printf '%s\n' 'before' >"$test_root/mutate-source/mutate"
printf '%s\n' 'after' >"$test_root/mutate-source/replacement"
sed "/listed = os.stat/a\\    if name == 'mutate': os.replace(os.path.join(source, 'replacement'), os.path.join(source, 'mutate'))" "$test_root/copy.py" >"$test_root/mutate.py"
if python3 -I "$test_root/mutate.py" "$test_root/mutate-source" "$test_root/mutate-destination" >/dev/null 2>&1; then
  printf '%s\n' 'legacy copy accepted a changed source identity' >&2; exit 1
fi
[[ ! -e "$test_root/mutate-destination/mutate" ]]

mkdir -p "$test_root/grow-source/deploy" "$test_root/grow-destination"
printf '%s\n' 'protected' >"$test_root/grow-source/deploy/.env"
printf '%s\n' 'before' >"$test_root/grow-source/grow"
sed "/while data := os.read/i\            if name == 'grow': fd = os.open(name, os.O_WRONLY | os.O_APPEND, dir_fd=source_fd); os.write(fd, b'x'); os.close(fd)" \
  "$test_root/copy.py" >"$test_root/grow.py"
if python3 -I "$test_root/grow.py" "$test_root/grow-source" "$test_root/grow-destination" >/dev/null 2>&1; then
  printf '%s\n' 'legacy copy accepted a source file that grew during streaming' >&2; exit 1
fi

mkdir -p "$test_root/large-source/deploy" "$test_root/large-destination"
printf '%s\n' 'protected' >"$test_root/large-source/deploy/.env"
truncate -s 67108865 "$test_root/large-source/over-limit"
if timeout 2s python3 -I "$test_root/copy.py" "$test_root/large-source" "$test_root/large-destination" >/dev/null 2>&1; then
  printf '%s\n' 'legacy copy accepted an over-limit file' >&2; exit 1
fi

# Exercise the installed program itself in a root-owned disposable namespace.
# No production prefix, engine, image inspection, or service operation is used.
command -v unshare >/dev/null 2>&1 || { printf '%s\n' 'root packet lifecycle fixture requires unshare'; exit 77; }
lifecycle_root="$(mktemp -d /tmp/root-packet-test.XXXXXX)"
trap 'rm -rf -- "$test_root" "$lifecycle_root"' EXIT
chmod 0700 "$lifecycle_root"
legacy_source="$lifecycle_root/home/completetrain/ai-agent-observability"
legacy_parent="$(dirname -- "$legacy_source")"
legacy_home="$(dirname -- "$legacy_parent")"
mkdir -p "$legacy_parent" "$lifecycle_root/srv" \
  "$lifecycle_root/var/backups" "$lifecycle_root/usr/local/sbin" "$lifecycle_root/etc"
chmod 0700 "$lifecycle_root" "$legacy_home" "$legacy_parent" \
  "$lifecycle_root/srv" "$lifecycle_root/var" "$lifecycle_root/var/backups" \
  "$lifecycle_root/usr" "$lifecycle_root/usr/local" "$lifecycle_root/usr/local/sbin" "$lifecycle_root/etc"
git clone --no-local --no-hardlinks --quiet "$repo_root" "$legacy_source"
printf '%s\n' 'fixture-only-secret' >"$legacy_source/deploy/.env"
packet_hash="$(sha256sum "$installer" | awk '{print $1}')"
synthetic_baseline="$(sha256sum "$legacy_source/deploy/compose.yaml" | awk '{print $1}')"
run_packet() {
  unshare -Ur env ROOT_PACKET_TEST_MODE=hermetic ROOT_PACKET_TEST_ROOT="$lifecycle_root" \
    READER_IMAGE_ID="sha256:$(printf '0%.0s' {1..64})" REVIEWED_PACKET_SHA256="$packet_hash" \
    ROOT_PACKET_TEST_BASELINE_SHA256="$synthetic_baseline" \
    "$installer" "$@"
}
run_packet --install
[[ -f "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade" ]]
[[ -f "$lifecycle_root/etc/ai-agent-observability-reviewed-upgrade.conf" ]]
[[ ! -e "$lifecycle_root/srv/ai-agent-observability-reviewed/live/.git" ]]
[[ ! -e "$lifecycle_root/var/backups/.ai-agent-observability-root-packet-partial-v3" ]]
run_packet --rollback-install
[[ ! -e "$lifecycle_root/srv/ai-agent-observability-reviewed" ]]

# A changed installed object must make rollback refuse deletion and preserve
# both the live tree and manifest for manual reconciliation.
run_packet --install
printf '%s\n' '# changed after installation' >>"$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade"
if run_packet --rollback-install >/dev/null 2>&1; then
  printf '%s\n' 'rollback deleted a changed installed object' >&2; exit 1
fi
[[ -d "$lifecycle_root/srv/ai-agent-observability-reviewed/live" ]]
[[ -f "$lifecycle_root/var/backups/ai-agent-observability-reviewed-upgrade/.root-packet-installation-v1" ]]
rm -rf -- "$lifecycle_root/srv/ai-agent-observability-reviewed" \
  "$lifecycle_root/var/backups/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/etc/ai-agent-observability-reviewed-upgrade.conf"

# Same bytes at a replacement inode must also block rollback deletion.
run_packet --install
cp "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/usr/local/sbin/replacement"
chmod 0755 "$lifecycle_root/usr/local/sbin/replacement"
mv "$lifecycle_root/usr/local/sbin/replacement" \
  "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade"
if run_packet --rollback-install >/dev/null 2>&1; then
  printf '%s\n' 'rollback deleted an identity-replaced installed object' >&2; exit 1
fi
[[ -f "$lifecycle_root/var/backups/ai-agent-observability-reviewed-upgrade/.root-packet-installation-v1" ]]
rm -rf -- "$lifecycle_root/srv/ai-agent-observability-reviewed" \
  "$lifecycle_root/var/backups/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/etc/ai-agent-observability-reviewed-upgrade.conf"

# Parent trust is an actual pre-creation guard, not a text assertion.
chmod 0777 "$lifecycle_root/var/backups"
if run_packet --install >/dev/null 2>&1; then
  printf '%s\n' 'installer accepted a group/world-writable destination ancestor' >&2; exit 1
fi
[[ ! -e "$lifecycle_root/srv/ai-agent-observability-reviewed" ]]
chmod 0700 "$lifecycle_root/var/backups"

# Failure after wrapper/config creation preserves their independently fsynced
# identities in the same journal used for the pre-creation root records.
if ROOT_PACKET_TEST_FAIL_AFTER_CONFIG=1 run_packet --install >/dev/null 2>&1; then
  printf '%s\n' 'post-configuration failure injection did not fail' >&2; exit 1
fi
partial="$lifecycle_root/var/backups/.ai-agent-observability-root-packet-partial-v3"
grep -Fq "created_file=$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade:" "$partial"
grep -Fq "created_file=$lifecycle_root/etc/ai-agent-observability-reviewed-upgrade.conf:" "$partial"
[[ -f "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade" ]]
[[ -f "$lifecycle_root/etc/ai-agent-observability-reviewed-upgrade.conf" ]]
rm -rf -- "$lifecycle_root/srv/ai-agent-observability-reviewed" \
  "$lifecycle_root/var/backups/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/var/backups/.ai-agent-observability-root-packet-partial-v3" \
  "$lifecycle_root/usr/local/sbin/ai-agent-observability-reviewed-upgrade" \
  "$lifecycle_root/etc/ai-agent-observability-reviewed-upgrade.conf"

# A post-create baseline failure must retain the durable journal and every
# created root for manual identity reconciliation rather than deleting them.
printf '%s\n' '# intentional baseline mismatch' >>"$legacy_source/deploy/compose.yaml"
if run_packet --install >/dev/null 2>&1; then
  printf '%s\n' 'installer accepted a changed baseline' >&2; exit 1
fi
partial="$lifecycle_root/var/backups/.ai-agent-observability-root-packet-partial-v3"
[[ -f "$partial" ]] && grep -Fq 'state=intent-recorded' "$partial" && grep -Fq 'created=' "$partial"
[[ -d "$lifecycle_root/srv/ai-agent-observability-reviewed/live" ]]
if run_packet --rollback-install >/dev/null 2>&1; then
  printf '%s\n' 'rollback accepted a partial installation journal' >&2; exit 1
fi
rm -rf -- "$lifecycle_root"
printf '%s\n' 'Reviewed root packet static boundaries passed.'
