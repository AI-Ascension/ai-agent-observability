#!/usr/bin/env bash
set -Eeuo pipefail

# Materialize a reviewed Git source tree at the existing non-Git deployment
# path. The target directory is never moved or replaced: existing bind-source
# files are overwritten in place so a file bind mount does not remain pinned to
# an old inode. The original tree is archived before the first target write and
# can be restored only while the reviewed materialization is still unchanged.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
candidate_root="$(cd -- "$script_dir/.." && pwd)"
live_root="${OTEL_LIVE_SOURCE_DIR:-}"
backup_root="${OTEL_MATERIALIZATION_BACKUP_ROOT:-}"
expected_head="${OTEL_EXPECTED_GIT_HEAD:-}"
mode="${1:---check}"
lock_fd=9
bind_paths=(deploy/compose.yaml deploy/otel-collector.yaml deploy/.env)

die() {
  printf 'otel source materializer: %s\n' "$1" >&2
  exit 1
}

case "$mode" in
  --check|--materialize|--rollback) ;;
  *) printf '%s\n' "usage: $0 [--check|--materialize|--rollback]" >&2; exit 64 ;;
esac

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

for command_name in git sha256sum stat readlink python3 tar flock cmp jq; do
  need_command "$command_name"
done

[[ -n "$expected_head" ]] || die 'OTEL_EXPECTED_GIT_HEAD is required'
[[ -n "$live_root" ]] || die 'OTEL_LIVE_SOURCE_DIR is required'
[[ -n "$backup_root" ]] || die 'OTEL_MATERIALIZATION_BACKUP_ROOT is required'

candidate_root="$(readlink -f -- "$candidate_root")"
live_root="$(readlink -f -- "$live_root")"
backup_root="$(readlink -m -- "$backup_root")"
[[ -d "$candidate_root/.git" || -f "$candidate_root/.git" ]] || die 'candidate source is not a Git checkout'
[[ -d "$live_root" ]] || die 'live source target is not a directory'
[[ ! -e "$live_root/.git" ]] || die 'live source target must remain a non-Git tree'
[[ "$candidate_root" != "$live_root" ]] || die 'candidate and live source paths must differ'
case "$backup_root/" in
  "$live_root"/*) die 'materialization backup must be outside the live source tree' ;;
esac

actual_head="$(git -C "$candidate_root" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual_head" == "$expected_head" ]] || die 'candidate source HEAD does not match OTEL_EXPECTED_GIT_HEAD'
candidate_status="$(git -C "$candidate_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$candidate_status" ]] || die 'candidate source checkout is dirty'

manifest_required=(
  deploy/Dockerfile.otel
  deploy/otel-health-probe.c
  deploy/otel-collector.yaml
  deploy/compose.yaml
  deploy/install-otel-health-probe.sh
  deploy/materialize-otel-source.sh
)
for relative_path in "${manifest_required[@]}"; do
  [[ -f "$candidate_root/$relative_path" && ! -L "$candidate_root/$relative_path" ]] || \
    die "candidate source file is missing or is a symlink: $relative_path"
done

mkdir -p -m 700 -- "$backup_root"
exec {lock_fd}>"$backup_root/materialize.lock"
flock -n "$lock_fd" || die 'another OTel source materialization is already running'

source_manifest_json() {
  local target_path="$1"
  local backup_dir="$2"
  python3 - "$candidate_root" "$target_path" "$backup_dir" "$expected_head" "${manifest_required[@]}" <<'PY'
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

candidate, target, backup, head, *required = sys.argv[1:]
raw = subprocess.check_output(["git", "-C", candidate, "ls-files", "-z"])
paths = [item for item in raw.decode().split("\0") if item]
entries = []
for rel in paths:
    path = Path(candidate) / rel
    st = path.lstat()
    if stat.S_ISREG(st.st_mode):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    elif stat.S_ISLNK(st.st_mode):
        digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
    else:
        raise SystemExit(f"unsupported tracked source type: {rel}")
    entries.append({
        "path": rel,
        "sha256": digest,
        "mode": stat.S_IMODE(st.st_mode),
        "type": "symlink" if stat.S_ISLNK(st.st_mode) else "file",
    })
seen = {entry["path"] for entry in entries}
missing = [path for path in required if path not in seen]
if missing:
    raise SystemExit(f"candidate manifest omits required files: {', '.join(missing)}")
print(json.dumps({
    "schema": "otel-source-materialization-v1",
    "source_head": head,
    "target_path": os.path.realpath(target),
    "backup_dir": os.path.realpath(backup),
    "files": entries,
}, sort_keys=True, separators=(",", ":")))
PY
}

capture_tree_manifest() {
  local tree="$1"
  local output="$2"
  python3 - "$tree" "$output" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2])
entries = []
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    base_path = Path(base)
    dirs[:] = sorted(dirs)
    files[:] = sorted(files)
    for name in dirs + files:
        path = base_path / name
        rel = path.relative_to(root).as_posix()
        st = path.lstat()
        if stat.S_ISDIR(st.st_mode):
            kind = "directory"
            digest = None
        elif stat.S_ISREG(st.st_mode):
            kind = "file"
            h = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(chunk)
            digest = h.hexdigest()
        elif stat.S_ISLNK(st.st_mode):
            kind = "symlink"
            digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
        else:
            raise SystemExit(f"unsupported target entry type: {rel}")
        entries.append({"path": rel, "type": kind, "mode": stat.S_IMODE(st.st_mode), "sha256": digest})
output.write_text(json.dumps({"schema":"otel-source-tree-v1", "entries":entries}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

capture_bind_state() {
  local tree="$1"
  local output="$2"
  python3 - "$tree" "$output" "${bind_paths[@]}" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2])
paths = sys.argv[3:]
entries = []
for rel in paths:
    path = root / rel
    if not path.exists() and not path.is_symlink():
        raise SystemExit(f"required bind-source path is missing: {rel}")
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise SystemExit(f"required bind-source path is not a regular file: {rel}")
    entries.append({
        "path": rel,
        "device": st.st_dev,
        "inode": st.st_ino,
        "mode": stat.S_IMODE(st.st_mode),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    })
output.write_text(json.dumps({"schema":"otel-bind-state-v1", "entries":entries}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

verify_tree_manifest() {
  local tree="$1"
  local manifest="$2"
  python3 - "$tree" "$manifest" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if data.get("schema") not in {"otel-source-materialization-v1", "otel-source-tree-v1"}:
    raise SystemExit("tree manifest schema is invalid")
entries = data.get("files", data.get("entries"))
if not isinstance(entries, list):
    raise SystemExit("tree manifest entries are missing")
for entry in entries:
    rel = entry.get("path")
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in Path(rel).parts:
        raise SystemExit("tree manifest contains an unsafe path")
    path = root / rel
    if not path.exists() and not path.is_symlink():
        raise SystemExit(f"tree manifest path is missing: {rel}")
    st = path.lstat()
    kind = entry.get("type")
    if kind == "file" and not stat.S_ISREG(st.st_mode):
        raise SystemExit(f"tree manifest expected a file: {rel}")
    if kind == "symlink" and not stat.S_ISLNK(st.st_mode):
        raise SystemExit(f"tree manifest expected a symlink: {rel}")
    if kind == "directory" and not stat.S_ISDIR(st.st_mode):
        raise SystemExit(f"tree manifest expected a directory: {rel}")
    if stat.S_IMODE(st.st_mode) != entry.get("mode"):
        raise SystemExit(f"tree manifest mode changed: {rel}")
    if kind == "file":
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    elif kind == "symlink":
        digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
    else:
        digest = None
    if digest != entry.get("sha256"):
        raise SystemExit(f"tree manifest content changed: {rel}")
PY
}

verify_bind_state() {
  local tree="$1"
  local manifest="$2"
  local strict="${3:-false}"
  python3 - "$tree" "$manifest" "$strict" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
strict = sys.argv[3] == "true"
if data.get("schema") != "otel-bind-state-v1":
    raise SystemExit("bind state schema is invalid")
for entry in data.get("entries", []):
    rel = entry["path"]
    path = root / rel
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_dev != entry["device"] or st.st_ino != entry["inode"]:
        raise SystemExit(f"bind-source inode changed: {rel}")
    if strict and stat.S_IMODE(st.st_mode) != entry["mode"]:
        raise SystemExit(f"bind-source mode changed: {rel}")
    if (strict or rel == "deploy/.env") and hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit(f"bind-source content changed: {rel}")
PY
}

if [[ "$mode" == --check ]]; then
  printf 'OTel source materialization preflight passed: candidate=%s target=%s\n' "$actual_head" "$live_root"
  exit 0
fi

if [[ "$mode" == --materialize ]]; then
  [[ "${OTEL_SOURCE_MATERIALIZE_APPROVED:-}" == true ]] || \
    die 'set OTEL_SOURCE_MATERIALIZE_APPROVED=true for materialization'
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  backup_dir="$backup_root/$stamp"
  mkdir -m 700 -- "$backup_dir"
  original_tree="$backup_dir/original-tree.tar"
  original_tree_manifest="$backup_dir/original-tree-manifest.json"
  original_bind_state="$backup_dir/original-bind-state.json"
  candidate_manifest="$backup_dir/candidate-source-manifest.json"
  state_file="$backup_dir/materialization-state.json"
  target_manifest="$live_root/deploy/.otel-source-manifest.json"
  [[ ! -e "$target_manifest" ]] || die 'target already contains a materialization manifest; rollback or reconcile it first'

  capture_tree_manifest "$live_root" "$original_tree_manifest"
  capture_bind_state "$live_root" "$original_bind_state"
  tar --xattrs --acls --numeric-owner -C "$live_root" -cpf "$original_tree" .
  sha256sum -- "$original_tree" >"$backup_dir/original-tree.tar.sha256"
  chmod 600 "$original_tree" "$backup_dir/original-tree.tar.sha256" "$original_tree_manifest" "$original_bind_state"
  source_manifest_json "$live_root" "$backup_dir" >"$candidate_manifest"
  chmod 600 "$candidate_manifest"

  candidate_tree="$backup_dir/candidate-tree.tar"
  tar --xattrs --acls --numeric-owner --exclude=.git --exclude=./.git -C "$candidate_root" -cpf "$candidate_tree" .
  tar --xattrs --acls --no-same-owner --preserve-permissions -C "$live_root" -xpf "$candidate_tree"
  rm -f -- "$candidate_tree"
  verify_tree_manifest "$live_root" "$candidate_manifest"
  verify_bind_state "$live_root" "$original_bind_state"
  cp -- "$candidate_manifest" "$target_manifest"
  chmod 0644 "$target_manifest"
  jq -n --arg target "$live_root" --arg backup "$backup_dir" --arg manifest "$target_manifest" \
    '{schema:"otel-source-materialization-state-v1",target_path:$target,backup_dir:$backup,target_manifest:$manifest,status:"materialized"}' \
    >"$state_file"
  chmod 600 "$state_file"
  printf 'OTel source materialized at %s; original backup=%s\n' "$live_root" "$backup_dir"
  exit 0
fi

backup_dir="${OTEL_MATERIALIZATION_BACKUP_DIR:-}"
[[ -n "$backup_dir" && -d "$backup_dir" ]] || die 'OTEL_MATERIALIZATION_BACKUP_DIR must name a materialization backup directory'
state_file="$backup_dir/materialization-state.json"
original_tree="$backup_dir/original-tree.tar"
original_tree_manifest="$backup_dir/original-tree-manifest.json"
original_bind_state="$backup_dir/original-bind-state.json"
candidate_manifest="$backup_dir/candidate-source-manifest.json"
[[ -f "$state_file" && -f "$original_tree" && -f "$backup_dir/original-tree.tar.sha256" && \
   -f "$original_tree_manifest" && -f "$original_bind_state" && -f "$candidate_manifest" ]] || \
  die 'materialization backup is incomplete'
[[ "$(jq -r '.schema // ""' "$state_file")" == otel-source-materialization-state-v1 ]] || die 'materialization state schema is invalid'
[[ "$(jq -r '.target_path // ""' "$state_file")" == "$live_root" ]] || die 'materialization backup target does not match OTEL_LIVE_SOURCE_DIR'
[[ "$(sha256sum -- "$original_tree" | awk '{print $1}')" == "$(awk '{print $1}' "$backup_dir/original-tree.tar.sha256")" ]] || \
  die 'original tree archive checksum is invalid'
verify_tree_manifest "$live_root" "$candidate_manifest"
verify_bind_state "$live_root" "$original_bind_state"
[[ ! -e "$live_root/.git" ]] || die 'live source target became a Git checkout before rollback'
cmp -s -- "$live_root/deploy/.otel-source-manifest.json" "$candidate_manifest" || \
  die 'materialized source manifest changed before rollback'

tar --xattrs --acls --no-same-owner --preserve-permissions -C "$live_root" -xpf "$original_tree"
python3 - "$live_root" "$candidate_manifest" "$original_tree_manifest" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
candidate = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
original = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
candidate_paths = {entry["path"] for entry in candidate["files"]}
original_paths = {entry["path"] for entry in original["entries"]}
for rel in sorted(candidate_paths - original_paths, key=lambda value: (value.count("/"), value), reverse=True):
    path = root / rel
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        raise SystemExit(f"candidate-only rollback path is not a file: {rel}")
PY
verify_tree_manifest "$live_root" "$original_tree_manifest"
if ! jq -e --arg path "deploy/.otel-source-manifest.json" \
    '[.entries[] | select(.path == $path)] | length == 0' "$original_tree_manifest" >/dev/null; then
  die 'original tree unexpectedly contained the generated source manifest'
fi
rm -f -- "$live_root/deploy/.otel-source-manifest.json"
verify_bind_state "$live_root" "$original_bind_state" true
jq '.status="rolled-back"' "$state_file" >"$state_file.tmp"
mv -f -- "$state_file.tmp" "$state_file"
chmod 600 "$state_file"
printf 'OTel source materialization rolled back at %s from %s\n' "$live_root" "$backup_dir"
