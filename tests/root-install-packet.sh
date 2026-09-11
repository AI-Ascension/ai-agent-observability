#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/deploy/install-reviewed-upgrade-root-packet.sh"

bash -n "$installer"
grep -Fq "readonly expected_head='c309c8e532574754609d9491f0a10be584f83a83'" "$installer"
grep -Fq "readonly legacy_root='/home/completetrain/ai-agent-observability'" "$installer"
grep -Fq "readonly reviewed_root='/srv/ai-agent-observability-reviewed'" "$installer"
grep -Fq "readonly backup_root='/var/backups/ai-agent-observability-reviewed-upgrade'" "$installer"
grep -Fq 'REVIEWED_PACKET_SHA256 must be the root-recorded installer SHA-256' "$installer"
grep -Fq 'installer content does not match the root-recorded review' "$installer"
grep -Fq -- '--install | --rollback-install' "$installer"
grep -Fq 'installation object identity changed; preserving data' "$installer"
grep -Fq 'installation content changed; preserving data' "$installer"
grep -Fq 'installation failed; preserving partial paths and any identity journal for review' "$installer"
grep -Fq 'rollback_state_name' "$installer"
grep -Fq 'trusted_new_parent' "$installer"
grep -Fq 'os.O_NONBLOCK | NOFOLLOW' "$installer"
grep -Fq 'source entry changed during open' "$installer"
! grep -Eq 'compose (up|down)|systemctl (start|stop|restart)|container (start|stop)|volume rm|image (pull|rm)' "$installer"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
sed -n '/^import os, stat, sys$/,/^PY$/p' "$installer" | sed '$d' >"$test_root/copy.py"
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
if timeout 2s python3 -I "$test_root/copy.py" "$test_root/fifo-source" "$test_root/fifo-destination" >/dev/null 2>&1; then
  printf '%s\n' 'legacy copy accepted a FIFO' >&2; exit 1
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

mkdir -p "$test_root/large-source/deploy" "$test_root/large-destination"
printf '%s\n' 'protected' >"$test_root/large-source/deploy/.env"
truncate -s 67108865 "$test_root/large-source/over-limit"
if timeout 2s python3 -I "$test_root/copy.py" "$test_root/large-source" "$test_root/large-destination" >/dev/null 2>&1; then
  printf '%s\n' 'legacy copy accepted an over-limit file' >&2; exit 1
fi
printf '%s\n' 'Reviewed root packet static boundaries passed.'
