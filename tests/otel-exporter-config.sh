#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat >"$work/config-test.c" <<'C'
#define main collector_probe_main
#include "otel-health-probe.c"
#undef main

int main(int argc, char **argv) {
    char config[max_config_bytes];
    struct active_exporters active;
    struct exporter_target target;
    FILE *file;
    size_t length;
    if (argc != 2 || (file = fopen(argv[1], "rb")) == NULL) return 1;
    length = fread(config, 1, sizeof(config), file);
    fclose(file);
    if (!active_trace_exporters(config, length, &active) || active.count != 2) return 1;
    if (!exporter_endpoint(config, length, "otlp_http/mlflow", &target) ||
        strcmp(target.host, "mlflow") != 0 || target.port != 5000) return 1;
    if (!exporter_endpoint(config, length, "otlp_http/laminar", &target) ||
        strcmp(target.host, "laminar-app-server") != 0 || target.port != 8000) return 1;
    const char duplicate[] = "exporters:\n  otlp_http/a:\n    endpoint: http://a:5000\n  otlp_http/a:\n    endpoint: http://b:8000\n";
    if (exporter_endpoint(duplicate, strlen(duplicate), "otlp_http/a", &target)) return 1;
    const char missing[] = "exporters:\n  otlp_http/a:\n    timeout: 10s\n  otlp_http/b:\n    endpoint: http://b:8000\n";
    if (exporter_endpoint(missing, strlen(missing), "otlp_http/a", &target)) return 1;
    return 0;
}
C
gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -I "$repo_root/deploy" \
  "$work/config-test.c" -o "$work/config-test"
"$work/config-test" "$repo_root/deploy/otel-collector.yaml"
echo 'Both deployed exporter endpoints resolve; duplicate and missing endpoints fail closed.'
