#!/usr/bin/env bash
# Run after strict manifest + filesystem admission. No creation or repair.
set -euo pipefail
[[ $# == 1 ]] || exit 64
manifest=$1
for role in data diagnostic; do
  root=$(awk -F '\t' -v key="$role.mountpoint" '$1 == key {print $2}' "$manifest")
  case "$role" in data) child=$root/clickhouse ;; diagnostic) child=$root/legacy-clickhouse ;; esac
  [[ -d "$child" && ! -L "$child" && $(realpath -e -- "$child") == "$child" ]] || {
    echo "$role bind directory is missing or noncanonical." >&2; exit 69;
  }
  read -r owner mode < <(stat -c '%u %a' -- "$root")
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 022) == 0 )) || {
    echo "$role mount root must prevent untrusted directory replacement." >&2; exit 69;
  }
  [[ $(stat -c %d -- "$child") == "$(stat -c %d -- "$root")" &&
     $(findmnt -n -o TARGET -T "$child") == "$root" ]] || {
    echo "$role bind directory is on an unexpected or nested mount." >&2; exit 69;
  }
done
