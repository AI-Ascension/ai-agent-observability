#!/usr/bin/env bash
# Pure parser fixtures: no Docker, network, credentials or deployment data.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT

# Build a complete positive model from the checked-in contract. This keeps the
# regression fixture honest when a reviewed port or mount is added, while all
# bind sources remain inside the isolated temporary project directory.
jq -n --arg project_dir "$test_root" --slurpfile contract_file "$repo_root/tests/compose-contract.json" '
  $contract_file[0] as $contract |
  def env($service):
    (($service.environment_keys | map({key: ., value: "fixture"}) | from_entries) *
      ($service.environment_values // {}));
  def build($value):
    if $value == null then null else
      ($value | .context = ($project_dir + "/deploy"))
    end;
  def depends($value):
    ($value | to_entries |
      map({key: .key, value: {condition: .value, required: true}}) | from_entries);
  def mounts($value):
    [$value[] |
      . as $mount |
      {type: $mount.type,
       source: (if $mount.type == "bind" then ($project_dir + "/" + $mount.source) else $mount.source end),
       target: $mount.target, read_only: ($mount.read_only // false)}];
  ($contract.services | to_entries | map({
    key: .key,
    value: {
      image: .value.image,
      build: build(.value.build),
      environment: env(.value),
      command: .value.command,
      depends_on: depends(.value.depends_on),
      networks: {default: null},
      ports: .value.ports,
      volumes: mounts(.value.volumes),
      cap_add: .value.cap_add,
      security_opt: .value.security_opt,
      read_only: .value.read_only,
      tmpfs: .value.tmpfs
    }
  }) | from_entries) as $services |
  {
    name: $contract.project_name,
    networks: {default: {name: $contract.network.name, external: true, ipam: {}}},
    services: $services,
    volumes: ($contract.volumes | with_entries(.value = {name: .value.name}))
  }
' > "$test_root/valid.json"

policy() {
  jq -e --arg project_dir "$1" --slurpfile contract_file "$repo_root/tests/compose-contract.json" \
    -f "$repo_root/tests/compose-policy.jq" "$2"
}

policy "$test_root" "$test_root/valid.json" >/dev/null

mutations=(
  # Approved service, environment and dependency boundaries.
  '.services["unapproved-egress"] = {image:"docker.io/library/alpine:3.22", environment:{AWS_SECRET_ACCESS_KEY:"marker"}, networks:{default:null}}'
  '.services.mlflow.environment.EXTRA_SECRET = "marker"'
  '.services.mlflow.depends_on["unapproved-egress"] = {condition:"service_started", required:true}'
  # Exact host path, mount, and top-level volume boundaries.
  '.services["laminar-clickhouse"].volumes += [{type:"bind",source:"/etc/shadow",target:"/run/host-shadow",read_only:true}]'
  '.services["laminar-clickhouse"].volumes[0].read_only = true'
  '.services["laminar-clickhouse"].volumes[0].source = "other-volume"'
  '.volumes["laminar-clickhouse-data"].driver_opts = {type:"none",o:"bind",device:"/etc/shadow"}'
  '.volumes["laminar-clickhouse-data"].external = true'
  '.secrets = {host_secret:{file:"/etc/shadow"}}'
  '.services.mlflow.env_file = ["/etc/shadow"]'
  # Exact network and published port inventories.
  '.networks.default.name = "shared-observability-network"'
  '.networks.shared = {name:"shared-network", external:true, ipam:{}}'
  '.services.mlflow.networks.shared = null'
  '.services["laminar-app-server"].ports = []'
  '.services["laminar-frontend"].ports = []'
  '.services["laminar-quickwit"].ports = []'
  '.services.mlflow.ports = []'
  '.services["mlflow-storage"].ports = []'
  '.services["otel-collector"].ports = []'
  '.services.mlflow.ports[0].host_ip = "0.0.0.0"'
  '.services.mlflow.ports[0].protocol = "udp"'
  # Namespace, device, capability and security confinement.
  '.services.mlflow.pid = "host"'
  '.services.mlflow.ipc = "host"'
  '.services.mlflow.uts = "host"'
  '.services.mlflow.privileged = true'
  '.services.mlflow.devices = ["/dev/kvm:/dev/kvm"]'
  '.services.mlflow.cap_add = ["ALL"]'
  '.services.mlflow.security_opt = ["seccomp:unconfined"]'
  # Both Laminar components must retain the telemetry and feature opt-outs.
  '.services["laminar-frontend"].environment.LAMINAR_TELEMETRY_DISABLED = "false"'
  '.services["laminar-frontend"].environment.POSTHOG_TELEMETRY = "true"'
  '{}'
)

for mutation in "${mutations[@]}"; do
  jq "$mutation" "$test_root/valid.json" > "$test_root/invalid.json"
  if policy "$test_root" "$test_root/invalid.json" > "$test_root/result" 2>&1; then
    printf 'Accepted invalid model mutation: %s\n' "$mutation" >&2
    exit 1
  fi
done

# Bind sources are anchored to the checkout supplied to the gate, so a valid
# model copied to a different project directory cannot silently widen the host boundary.
if policy /different/project "$test_root/valid.json" > "$test_root/result" 2>&1; then
  printf '%s\n' 'Accepted model with an unrelated project directory' >&2
  exit 1
fi

printf '{broken' > "$test_root/invalid.json"
if policy "$test_root" "$test_root/invalid.json" > "$test_root/result" 2>&1; then
  echo 'Accepted malformed JSON' >&2
  exit 1
fi

# The canonical structured gate must ignore ambient interpolation variables.
if ! PATH="${PATH}" BIND_ADDRESS=0.0.0.0 AWS_SECRET_ACCESS_KEY=ambient-marker \
    bash tests/compose-structured.sh >/dev/null; then
  printf '%s\n' 'Structured gate was affected by ambient interpolation variables' >&2
  exit 1
fi

printf 'Structured Compose policy: 1 positive, %s negative cases passed.\n' "$(( ${#mutations[@]} + 2 ))"
