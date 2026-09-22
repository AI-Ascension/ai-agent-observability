/*
 * otel-probe/health.h — active dependency health checks.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_HEALTH_H
#define OTEL_PROBE_HEALTH_H

static int dependencies_are_healthy(int64_t deadline) {
    char config[max_config_bytes];
    size_t length;
    struct active_exporters active;

    if (!read_collector_config(config, sizeof(config), &length)) {
        return 0;
    }
    if (!active_trace_exporters(config, length, &active)) {
        return 0;
    }
    for (size_t index = 0; index < active.count; ++index) {
        struct exporter_target target;

        if (!exporter_endpoint(config, length, active.names[index], &target)) {
            return 0;
        }
        if (!http_endpoint_is_healthy(target.host, target.port, "/health", deadline)) {
            return 0;
        }
    }
    return 1;
}
#endif /* OTEL_PROBE_HEALTH_H */
