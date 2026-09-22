#!/usr/bin/env bash
# Provisioning common helpers — fatal errors and dotenv value parsing
#
# Extracted verbatim from deploy/laminar/provision-query-readonly.sh by the
# behavior-preserving module split in issue #47. This file is sourced by the
# provisioning coordinator: it only defines functions and is never executed
# directly, so the shared globals stay in one shell.
#
# ShellCheck cannot follow the coordinator `source` chain; the cross-file
# diagnostics are disabled file-wide.
# shellcheck disable=SC2034,SC2154

die() {
  local status="$1"
  shift
  printf '%s\n' "$*" >&2
  exit "$status"
}

read_dotenv_value() {
  local wanted="$1"
  local required="$2"
  if [[ -z "$required" ]]; then
    required=true
  fi
  python3 - "$env_file" "$wanted" "$required" <<'PY'
import ast
import sys

path, wanted, required = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, separator, value = line.partition("=")
        if separator and name.strip() == wanted:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = ast.literal_eval(value)
            print(value)
            raise SystemExit(0)
if required == "true":
    raise SystemExit(69)
PY
}
