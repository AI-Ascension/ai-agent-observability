# Check the parsed, normalized Compose model, not coincidental YAML text.
# The contract is deliberately small and describes the approved topology.  It is
# loaded with --slurpfile so this filter has no ambient file or network input.
def object_or_empty:
  if type == "object" then . else {} end;

def normalized_build($value):
  if $value == null then null
  elif ($value | type) == "object" then
    ($value | {
      context: (if .context == ($project_dir + "/deploy") then "deploy" else .context end),
      dockerfile: (.dockerfile // null),
      target: (.target // null),
      args: (.args // {})
    })
  else {invalid: true}
  end;

def normalized_port:
  . as $port |
  if ($port | type) != "object" or
     (((($port | keys) - ["host_ip", "published", "target", "protocol", "mode", "name", "app_protocol"]) | length) != 0) or
     ($port.name != null) or ($port.app_protocol != null) then
    {invalid: true}
  else
    {
      host_ip: $port.host_ip,
      published: ($port.published | tostring),
      target: $port.target,
      protocol: ($port.protocol // "tcp"),
      mode: ($port.mode // "ingress")
    }
  end;

def normalized_ports($value):
  if $value == null then []
  elif ($value | type) == "array" then [$value[] | normalized_port]
  else [{invalid: true}]
  end;

def normalized_mount:
  . as $mount |
  if ($mount | type) != "object" or
     (((($mount | keys) - ["type", "source", "target", "read_only", "bind", "volume"]) | length) != 0) then
    {invalid: true}
  else
    {
      type: $mount.type,
      source: $mount.source,
      target: $mount.target,
      read_only: ($mount.read_only // false),
      bind: ($mount.bind // null),
      volume: ($mount.volume // null)
    }
  end;

def normalized_mounts($value):
  if $value == null then []
  elif ($value | type) == "array" then [$value[] | normalized_mount]
  else [{invalid: true}]
  end;

def expected_mounts($value):
  if ($value | type) == "array" then
    [$value[] |
      {
        type: .type,
        source: (if .type == "bind" then ($project_dir + "/" + .source) else .source end),
        target: .target,
        read_only: (.read_only // false),
        bind: (if .type == "bind" then {create_host_path: true} else null end),
        volume: (if .type == "volume" then {} else null end)
      }]
  else [{invalid: true}]
  end;

def normalized_depends($value):
  if $value == null then {}
  elif ($value | type) == "object" then
    ($value | with_entries(.value = {
      condition: .value.condition,
      required: (.value.required // true)
    }))
  else {"<invalid>": {condition: null, required: false}}
  end;

def expected_depends($value):
  if ($value | type) == "object" then
    ($value | with_entries(.value = {condition: .value, required: true}))
  else {"<invalid>": {condition: null, required: false}}
  end;

def environment_keys($value):
  if $value == null then []
  elif ($value | type) == "object" then ($value | keys)
  else ["<invalid>"]
  end;

def volume_declaration($value):
  if ($value | type) == "object" then
    ($value | {
      name: .name,
      driver: (.driver // "local"),
      driver_opts: (.driver_opts // {}),
      external: (.external // false)
    })
  else {invalid: true}
  end;

def valid_model:
  . as $model |
  $contract_file[0] as $contract |
  (($model | type) == "object") and
  (($model | keys) == ["name", "networks", "services", "volumes"]) and
  ($model.name == $contract.project_name) and
  (($model.services | object_or_empty | keys) == ($contract.services | keys)) and
  (($model.networks | object_or_empty | keys) == ["default"]) and
  (($model.networks.default | object_or_empty | keys - ["external", "ipam", "name"]) == []) and
  (($model.networks.default | object_or_empty |
    {name: .name, external: .external, ipam: (.ipam // {})}) ==
    {name: $contract.network.name, external: $contract.network.external, ipam: {}}) and
  (($model.volumes | object_or_empty | keys) == ($contract.volumes | keys)) and
  (all(($model.volumes | object_or_empty | to_entries[]);
    .value as $actual |
    (($actual | type) == "object") and
    (($actual | keys - ["name", "driver", "driver_opts", "external"]) == []) and
    (volume_declaration($actual) == {
      name: $contract.volumes[.key].name,
      driver: ($contract.volumes[.key].driver // "local"),
      driver_opts: ($contract.volumes[.key].driver_opts // {}),
      external: ($contract.volumes[.key].external // false)
    }))) and
  (all(($model.services | object_or_empty | to_entries[]);
    .key as $name |
    .value as $actual |
    $contract.services[$name] as $expected |
    (($actual | type) == "object") and
    (($actual | keys - $contract.service_fields) == []) and
    (($actual | keys | map(select(. == "pid" or . == "ipc" or . == "uts" or
      . == "network_mode" or . == "privileged" or . == "devices" or
      . == "device_cgroup_rules" or . == "cap_drop" or . == "sysctls" or
      . == "userns_mode" or . == "volumes_from" or . == "runtime" or
      . == "cgroupns" or . == "env_file" or . == "secrets" or . == "configs"))) == []) and
    (if $actual.build == null then true else
      (($actual.build | type) == "object" and
       (($actual.build | keys - ["args", "context", "dockerfile", "target"]) == []))
    end) and
    ($actual.image == $expected.image) and
    (normalized_build($actual.build) == $expected.build) and
    (environment_keys($actual.environment) == $expected.environment_keys) and
    (all(($expected.environment_values // {}) | to_entries[];
      $actual.environment[.key] == .value)) and
    ($actual.container_name == $expected.container_name) and
    ($actual.entrypoint == $expected.entrypoint) and
    ($actual.restart == $expected.restart) and
    ($actual.pull_policy == $expected.pull_policy) and
    ($actual.healthcheck == $expected.healthcheck) and
    (($actual.ulimits // {}) == ($expected.ulimits // {})) and
    (($actual.networks // {}) == {default: null}) and
    (($actual.command // null) == $expected.command) and
    (normalized_depends($actual.depends_on) == expected_depends($expected.depends_on)) and
    (normalized_ports($actual.ports) == $expected.ports) and
    (normalized_mounts($actual.volumes) == expected_mounts($expected.volumes)) and
    (($actual.cap_add // []) == $expected.cap_add) and
    (($actual.security_opt // []) == $expected.security_opt) and
    (($actual.read_only // false) == $expected.read_only) and
    (($actual.tmpfs // []) == $expected.tmpfs)
  ));

if valid_model then true else error("deployment model violates bounded local standards") end
