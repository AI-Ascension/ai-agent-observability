#!/usr/bin/env bash
# Privileged lifecycle wrapper: validate the manifest and every parent directory.
set -euo pipefail
[[ $# == 1 && $EUID == 0 ]] || { echo 'Root and one manifest path required.' >&2; exit 77; }
path=$1
[[ -f "$path" && "$path" == /* && $(realpath -e -- "$path") == "$path" ]] || exit 64
while :; do
  [[ ! -L "$path" ]] || exit 64
  read -r owner mode < <(stat -c '%u %a' -- "$path")
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] || exit 64
  (( (8#$mode & 022) == 0 )) || exit 64
  [[ "$path" != / ]] || break
  path=$(dirname -- "$path")
done
