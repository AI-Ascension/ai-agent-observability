#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the production wrapper body against a private fake engine.  The copied
# entrypoint relaxes only installation ownership/path predicates: that lets an
# ordinary test user build a disposable fixture, while exercising the actual
# baseline inventory, materialization, stop, archive, compose-failure trap,
# journal, and exact-new-container compensation code without Podman.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_wrapper="$repo_root/deploy/ai-agent-observability-reviewed-upgrade"
root="$(mktemp -d)"
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root"/{bin,backup,live/deploy,candidate/deploy}
chmod 700 "$root/backup"
cp "$source_wrapper" "$root/wrapper"
sed -i \
  -e "s#readonly install_config='/etc/ai-agent-observability-reviewed-upgrade.conf'#readonly install_config='$root/config'#" \
  -e 's/\[\[ "$(id -u)" -eq 0 \]\]/true/' \
  -e "s#\[\[ \"\$engine_bin\" == /usr/bin/podman \]\]#\[\[ \"\$engine_bin\" == '$root/bin/engine' \]\]#" \
  -e 's/== 0:700/== $(id -u):700/' \
  -e 's/target_stat.st_uid != 0 or stat.S_IMODE(target_stat.st_mode) & 0o022/False/' \
  "$root/wrapper"
# Test adapter overrides only the root-owned installation boundary functions.
sed -i "/deployment_root=''; candidate_root=/i trusted_regular() { [[ -f \"\$1\" && ! -L \"\$1\" ]]; }\ntrusted_directory() { [[ -d \"\$1\" && ! -L \"\$1\" ]]; }\ntrusted_path() { [[ \"\$1\" == /* && -e \"\$1\" && ! -L \"\$1\" ]]; }\ntrusted_candidate_tree() { [[ -d \"\$candidate_root\" ]]; }" "$root/wrapper"
chmod 700 "$root/wrapper"
printf 'legacy compose\n' >"$root/live/deploy/compose.yaml"
printf 'secret\n' >"$root/live/deploy/.env"; chmod 600 "$root/live/deploy/.env"
printf 'legacy collector\n' >"$root/live/deploy/otel-collector.yaml"
printf 'legacy Dockerfile\n' >"$root/live/deploy/Dockerfile.otel"
printf 'services: {}\n' >"$root/candidate/deploy/compose.yaml"
printf 'collector\n' >"$root/candidate/deploy/otel-collector.yaml"
printf 'Dockerfile\n' >"$root/candidate/deploy/Dockerfile.otel"
cat >"$root/candidate/deploy/materialize-otel-source.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == --rollback ]]; then touch "$OTEL_LIVE_SOURCE_DIR/rollback-ran"; exit 0; fi
mkdir -p "$OTEL_MATERIALIZATION_BACKUP_ROOT/point"
printf '{}\n' >"$OTEL_MATERIALIZATION_BACKUP_ROOT/point/materialization-state.json"
base="$(dirname -- "$0")"
for f in compose.yaml otel-collector.yaml Dockerfile.otel materialize-otel-source.sh; do cp "$base/$f" "$OTEL_LIVE_SOURCE_DIR/deploy/$f"; done
EOF
chmod 700 "$root/candidate/deploy/materialize-otel-source.sh"
git -C "$root/candidate" init -q
git -C "$root/candidate" config user.name fixture
git -C "$root/candidate" config user.email fixture@example.invalid
git -C "$root/candidate" add deploy && git -C "$root/candidate" commit -qm fixture
head="$(git -C "$root/candidate" rev-parse HEAD)"
compose_sha="$(sha256sum "$root/candidate/deploy/compose.yaml" | awk '{print $1}')"
collector_sha="$(sha256sum "$root/candidate/deploy/otel-collector.yaml" | awk '{print $1}')"
dockerfile_sha="$(sha256sum "$root/candidate/deploy/Dockerfile.otel" | awk '{print $1}')"
baseline_sha="$(sha256sum "$root/live/deploy/compose.yaml" | awk '{print $1}')"
cat >"$root/config" <<EOF
DEPLOYMENT_ROOT=$root/live
CANDIDATE_ROOT=$root/candidate
BACKUP_ROOT=$root/backup
ENGINE_BIN=$root/bin/engine
READER_IMAGE_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BASELINE_COMPOSE_SHA256=$baseline_sha
EOF
chmod 600 "$root/config"
cat >"$root/bin/engine" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
s="$(dirname -- "$0")/state"; p=ai-agent-observability
base=(mlflow-postgres mlflow-storage mlflow-create-bucket mlflow laminar-postgres laminar-clickhouse laminar-rabbitmq laminar-quickwit laminar-app-server laminar-frontend laminar-bootstrap otel-collector)
vol=(mlflow-postgres-data mlflow-storage-data laminar-clickhouse-data laminar-clickhouse-logs laminar-postgres-data laminar-quickwit-data)
ident() { printf '%064d' "$1" | tr ' ' 0; }
case "$1:$2" in
image:inspect) printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
ps:-a) for x in "${base[@]}"; do echo "$p-$x"; done; if [[ $(<"$s/mode") == unknown ]]; then echo "$p-foreign"; fi ;;
volume:ls) for x in "${vol[@]}"; do echo "$p-$x"; done ;;
volume:inspect) n="${!#}"; case "$n" in *laminar-rabbitmq-data|*otel-collector-data) [[ -e "$s/new" ]] || exit 125;; esac; echo "$n" ;;
network:ls) echo "$p-net" ;;
network:inspect) echo "$(ident 77)|${!#}" ;;
container:inspect) n="${!#}"; x="${n#$p-}"; [[ "$x" == otel-collector-storage-init && ! -e "$s/new" ]] && exit 125; for a in "$@"; do [[ "$a" == *'.State.Running'* ]] && { echo false; exit; }; done; i=1; [[ "$x" == otel-collector-storage-init ]] && i=99; echo "$(ident "$i")|$p|$x" ;;
container:stop) touch "$s/stopped-${!#}" ;;
container:rm) touch "$s/removed-${!#}"; rm -f "$s/new" ;;
run:--rm) for a in "$@"; do [[ "$a" == *:/backup:rw ]] && out="${a%:/backup:rw}"; [[ "$a" == /backup/*.tar ]] && tar="${a#/backup/}"; done; printf x >"$out/$tar" ;;
compose:*) touch "$s/new"; [[ $(<"$s/mode") == partial ]] && exit 1 ;;
*) exit 125 ;;
esac
EOF
chmod 700 "$root/bin/engine"
run_case() {
  local mode="$1" state="$root/$1"; mkdir "$state"; printf '%s\n' "$mode" >"$state/mode"
  set +e
  ln -sfn "$state" "$root/bin/state"
  "$root/wrapper" --candidate-head "$head" --candidate-compose-sha256 "$compose_sha" --candidate-collector-sha256 "$collector_sha" --candidate-dockerfile-sha256 "$dockerfile_sha" >"$state/out" 2>"$state/err"
  local rc=$?; set -e; printf '%s\n' "$rc" >"$state/rc"
  [[ "$rc" == 0 ]] || sed -n '1,80p' "$state/err" >&2
}
run_case unknown
[[ $(<"$root/unknown/rc") != 0 && ! -e "$root/live/rollback-ran" ]]
run_case partial
[[ $(<"$root/partial/rc") != 0 && -e "$root/live/rollback-ran" ]]
[[ -e "$root/partial/removed-ai-agent-observability-otel-collector-storage-init" ]]
[[ -e "$root/partial/stopped-ai-agent-observability-otel-collector" ]]
journal="$(find "$root/backup" -name baseline-objects.json -print -quit)"
[[ -n "$journal" ]] && grep -Fq 'otel-collector-storage-init' "$journal"
printf '%s\n' 'Reviewed upgrade wrapper fake-engine migration and partial-update compensation fixture passed.'
