#!/usr/bin/env bash
# OTel installer runtime helpers — container runtime identity and contract verification
#
# Extracted verbatim from deploy/install-otel-health-probe.sh by the
# behavior-preserving module split in issue #45. This file is sourced by the
# installer coordinator and defines functions only; it is never executed
# directly.
#
# ShellCheck cannot follow the coordinator's `source` chain, so shared
# globals and helper functions appear "unused" or "unassigned" per file.
# The two diagnostics below are disabled file-wide for that reason.
# shellcheck disable=SC2034,SC2154

runtime_identity() {
  local inspect_json="$1"
  # Keep the complete runtime contract secret-safe and stable across a
  # recreation: dynamic IP addresses are excluded, while every requested
  # command, port, network, device, and resource setting is compared.
  jq -cS '
    .[0] as $c |
    {
      config: {
        entrypoint: ($c.Config.Entrypoint // []),
        cmd: ($c.Config.Cmd // []),
        exposed_ports: (($c.Config.ExposedPorts // {}) | to_entries | sort_by(.key)),
        user: ($c.Config.User // ""),
        working_dir: ($c.Config.WorkingDir // ""),
        stop_signal: ($c.Config.StopSignal // "")
      },
      host: {
        port_bindings: (($c.HostConfig.PortBindings // {}) | to_entries | sort_by(.key) |
          map({port:.key, bindings:(.value // [] | sort_by(.HostIp,.HostPort) |
            map({host_ip:(.HostIp // ""), host_port:(.HostPort // "")}))})),
        publish_all_ports: ($c.HostConfig.PublishAllPorts // false),
        network_mode: ($c.HostConfig.NetworkMode // ""),
        extra_hosts: (($c.HostConfig.ExtraHosts // []) | sort),
        devices: (($c.HostConfig.Devices // []) | map({host:(.PathOnHost // ""),container:(.PathInContainer // ""),permissions:(.CgroupPermissions // "")}) | sort_by(.host,.container,.permissions)),
        device_requests: (($c.HostConfig.DeviceRequests // []) | map({driver:(.Driver // ""),count:(.Count // 0),device_ids:(.DeviceIDs // [] | sort),capabilities:(.Capabilities // [] | map(sort) | sort)}) | sort_by(.driver,.count,.device_ids)),
        resources: {
          blkio_weight: ($c.HostConfig.BlkioWeight // 0),
          cpu_count: ($c.HostConfig.CpuCount // 0),
          cpu_percent: ($c.HostConfig.CpuPercent // 0),
          cpu_period: ($c.HostConfig.CpuPeriod // 0),
          cpu_quota: ($c.HostConfig.CpuQuota // 0),
          cpu_realtime_period: ($c.HostConfig.CpuRealtimePeriod // 0),
          cpu_realtime_runtime: ($c.HostConfig.CpuRealtimeRuntime // 0),
          cpu_shares: ($c.HostConfig.CpuShares // 0),
          cpuset_cpus: ($c.HostConfig.CpusetCpus // ""),
          cpuset_mems: ($c.HostConfig.CpusetMems // ""),
          nano_cpus: ($c.HostConfig.NanoCpus // 0),
          memory: ($c.HostConfig.Memory // 0),
          memory_reservation: ($c.HostConfig.MemoryReservation // 0),
          memory_swap: ($c.HostConfig.MemorySwap // 0),
          memory_swappiness: ($c.HostConfig.MemorySwappiness // 0),
          oom_kill_disable: ($c.HostConfig.OomKillDisable // false),
          pids_limit: ($c.HostConfig.PidsLimit // 0),
          ulimits: (($c.HostConfig.Ulimits // []) | map({name:(.Name // ""),soft:(.Soft // 0),hard:(.Hard // 0)}) | sort_by(.name))
        },
        readonly_rootfs: ($c.HostConfig.ReadonlyRootfs // false),
        security_opt: (($c.HostConfig.SecurityOpt // []) | sort),
        cap_add: (($c.HostConfig.CapAdd // []) | sort),
        cap_drop: (($c.HostConfig.CapDrop // []) | sort),
        privileged: ($c.HostConfig.Privileged // false),
        tmpfs: (($c.HostConfig.Tmpfs // {}) | to_entries | sort_by(.key)),
        restart_policy: ($c.HostConfig.RestartPolicy // {})
      },
      networks: (($c.NetworkSettings.Networks // {}) | to_entries |
        map({name:.key, aliases:(.value.Aliases // [] | sort)}) | sort_by(.name)),
      mounts: (($c.Mounts // []) | map({type:(.Type // ""),source:(.Source // ""),destination:(.Destination // ""),mode:(.Mode // ""),rw:(.RW // false)}) | sort_by(.destination,.source,.type))
    }
  ' <<<"$inspect_json"
}
healthcheck_contract_matches() {
  local inspect_json="$1"
  jq -e --arg probe "$probe_path" '
    .[0].Config.Healthcheck as $health |
    ($health | type) == "object" and
    ($health.Test == ["CMD", $probe]) and
    ($health.Interval == 30000000000) and
    ($health.Timeout == 5000000000) and
    ($health.StartPeriod == 30000000000) and
    ($health.Retries == 3)
  ' <<<"$inspect_json" >/dev/null
}
healthcheck_identity_matches() {
  local inspect_json="$1"
  local expected_sha256="$2"
  [[ "$(jq -cS '.[0].Config.Healthcheck // null' <<<"$inspect_json" | \
    sha256sum | awk '{print $1}')" == "$expected_sha256" ]]
}
metrics_port_binding_contract_matches() {
  local inspect_json="$1"
  local binding_result
  binding_result="$(jq -r --arg host_port "$metrics_port" '
    .[0].HostConfig.PortBindings as $bindings |
    (($bindings["8888/tcp"] // []) | length) == 1 and
    (($bindings["8888/tcp"][0].HostIp // "") == "127.0.0.1") and
    (($bindings["8888/tcp"][0].HostPort // "") == $host_port)
  ' <<<"$inspect_json")" || return 1
  [[ "$binding_result" == true ]]
}
assert_active_container_unchanged() {
  local current_json current_id current_image
  current_json="$(bounded_capture 'active Collector identity recheck' "$inspect_timeout_seconds" \
    "${engine[@]}" inspect "$container_name")" || return 1
  current_id="$(jq -r '.[0].Id // ""' <<<"$current_json")" || return 1
  current_image="$(jq -r '.[0].Image // ""' <<<"$current_json")" || return 1
  [[ "$current_id" == "$active_container_id" && "$current_image" == "$active_image_id" ]] || return 1
}
verify_runtime_state() {
  local expected_image="$1"
  local expected_config="$2"
  local expected_env_digest="$3"
  local expected_full_env_digest="$4"
  local expected_health="$5"
  local expected_runtime="$6"
  local expected_container="${7:-}"
  local healthcheck_mode="${8:-candidate}"
  local expected_healthcheck_sha256="${9:-$active_healthcheck_sha256}"
  local expected_user="${10:-$runtime_expected_config_user}"
  local inspect_json image_id mounts env_text health_raw health labels runtime_sha256 cp_seconds state_status config_user
  local mount_count=0
  local temp

  inspect_json="$(bounded_capture 'runtime identity inspect' "$inspect_timeout_seconds" \
    "${engine[@]}" inspect "$container_name")" || return 1
  observed_runtime_container_id="$(jq -r '.[0].Id // ""' <<<"$inspect_json")" || return 1
  [[ -n "$observed_runtime_container_id" ]] || return 1
  if [[ -n "$expected_container" && "$observed_runtime_container_id" != "$expected_container" ]]; then
    return 1
  fi
  image_id="$(jq -r '.[0].Image // ""' <<<"$inspect_json")" || return 1
  [[ "$image_id" == "$expected_image" ]] || return 1
  config_user="$(jq -r '.[0].Config.User // ""' <<<"$inspect_json")" || return 1
  if [[ -n "$expected_user" && "$config_user" != "$expected_user" ]]; then
    return 1
  fi
  labels="$(jq -r '.[0].Config.Labels as $l | (($l["com.docker.compose.project"] // "") + "\t" + ($l["com.docker.compose.service"] // ""))' <<<"$inspect_json")" || return 1
  [[ "$labels" == "$project_name"$'\t'otel-collector ]] || return 1
  metrics_port_binding_contract_matches "$inspect_json" || return 1
  runtime_sha256="$(runtime_identity "$inspect_json" | sha256sum | awk '{print $1}')" || return 1
  [[ "$runtime_sha256" == "$expected_runtime" ]] || return 1
  mounts="$(jq -r '.[0].Mounts[]? | [.Type,.Source,.Destination,.RW,.Mode] | @tsv' <<<"$inspect_json")" || return 1
  while IFS=$'\t' read -r mount_type mount_source mount_target mount_rw mount_mode; do
    [[ -n "${mount_target:-}" ]] || continue
    if [[ "$mount_target" == "$mount_destination" ]]; then
      ((mount_count += 1))
      [[ "$mount_count" == 1 && "$mount_type" == bind && "$mount_source" == "$expected_mount_source" && \
         "$mount_rw" == false ]] || return 1
    fi
  done <<<"$mounts"
  [[ "$mount_count" == 1 ]] || return 1
  temp="$(mktemp -d)" || return 1
  cp_seconds="$(operation_timeout "$inspect_timeout_seconds")" || {
    rm -rf -- "$temp"
    return 1
  }
  if ! timeout --kill-after="${timeout_kill_after_seconds}s" "${cp_seconds}s" \
      "${engine[@]}" cp "$container_name:$mount_destination" "$temp/config.yaml" >/dev/null 2>&1; then
    rm -rf -- "$temp"
    return 1
  fi
  if [[ "$(sha256_file "$temp/config.yaml")" != "$expected_config" ]]; then
    rm -rf -- "$temp"
    return 1
  fi
  rm -rf -- "$temp"
  env_text="$(jq -r '.[0].Config.Env[]?' <<<"$inspect_json")" || return 1
  verify_env_text "$env_text" || return 1
  [[ "$(env_identity "$env_text")" == "$expected_env_digest" ]] || return 1
  [[ "$(env_identity_all "$env_text")" == "$expected_full_env_digest" ]] || return 1
  health_raw="$(jq -r '.[0].State.Health.Status // "missing"' <<<"$inspect_json")" || return 1
  health="$(canonical_health_status "$health_raw")" || return 1
  [[ "$health" == "$expected_health" ]] || return 1
  state_status="$(jq -r '.[0].State.Status // "missing"' <<<"$inspect_json")" || return 1
  [[ "$state_status" == running ]] || return 1
  if [[ "$healthcheck_mode" == candidate ]]; then
    healthcheck_contract_matches "$inspect_json" || return 1
  elif [[ "$healthcheck_mode" == baseline ]]; then
    healthcheck_identity_matches "$inspect_json" "$expected_healthcheck_sha256" || return 1
  else
    return 1
  fi
  return 0
}

