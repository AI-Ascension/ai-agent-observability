/*
 * A small, dependency-free healthcheck for the distroless Collector image.
 *
 * The production invocation intentionally has no arguments.  --port is kept
 * as a loopback-only test seam so the source test can exercise positive,
 * negative, and timeout responses without changing the runtime contract.
 */
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef OTEL_HEALTH_PROBE_DEFAULT_PORT
#define OTEL_HEALTH_PROBE_DEFAULT_PORT 13133
#endif
#ifndef OTEL_HEALTH_PROBE_DNS_PORT
#define OTEL_HEALTH_PROBE_DNS_PORT 53
#endif
#ifndef OTEL_HEALTH_PROBE_CONFIG_PATH
#define OTEL_HEALTH_PROBE_CONFIG_PATH "/etc/otelcol-contrib/config.yaml"
#endif
#ifndef OTEL_HEALTH_PROBE_DNS_SERVER
#define OTEL_HEALTH_PROBE_DNS_SERVER ""
#endif

enum {
    default_port = OTEL_HEALTH_PROBE_DEFAULT_PORT,
    dns_port = OTEL_HEALTH_PROBE_DNS_PORT,
    timeout_ms = 2000,
    max_response_bytes = 8192,
    max_config_bytes = 32768,
    max_json_string_bytes = 64,
    max_dns_name_bytes = 256,
    max_dns_answers = 64,
    max_json_depth = 16,
    max_object_members = 128,
    max_array_elements = 128,
    max_active_exporters = 32,
    max_exporter_name_bytes = 128,
    max_exporter_host_bytes = 256,
};

static const char collector_config_path[] = OTEL_HEALTH_PROBE_CONFIG_PATH;
static const char dns_server[] = OTEL_HEALTH_PROBE_DNS_SERVER;

/*
 * Module layout (issue #46 behavior-preserving split): the probe stays a
 * single static translation unit. Cohesive fragments are included in their
 * original source order so every definition still precedes its first use.
 *
 *   otel-probe/time_io.h    monotonic time, timeouts, non-blocking flags
 *   otel-probe/dns.h        bounded static DNS resolver
 *   otel-probe/http.h       TCP connect + bounded HTTP request/response
 *   otel-probe/config.h     Collector config load + YAML scanning
 *   otel-probe/exporters.h  active exporter parsing + endpoints
 *   otel-probe/health.h     dependency health checks
 *   otel-probe/json.h       bounded JSON parsing + health evaluation
 */
#include "otel-probe/time_io.h"
#include "otel-probe/dns.h"
#include "otel-probe/http.h"
#include "otel-probe/config.h"
#include "otel-probe/exporters.h"
#include "otel-probe/health.h"
#include "otel-probe/json.h"

static int parse_port(const char *value, int *port) {
    char *end = NULL;
    long parsed;

    errno = 0;
    parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed < 1 || parsed > 65535) {
        return 0;
    }
    *port = (int)parsed;
    return 1;
}

int main(int argc, char **argv) {
    int port = default_port;
    int test_seam = 0;
    int fd;
    int64_t deadline;
    char response[max_response_bytes + 1];
    size_t length;
    char *body;
    char *separator;

    if (argc == 3 && strcmp(argv[1], "--port") == 0) {
        if (!parse_port(argv[2], &port)) {
            return 2;
        }
        test_seam = 1;
    } else if (argc != 1) {
        (void)fprintf(stderr, "usage: %s [--port LOOPBACK_PORT]\n", argv[0]);
        return 2;
    }
    deadline = monotonic_millis();
    if (deadline < 0 || deadline > INT64_MAX - timeout_ms) {
        return EXIT_FAILURE;
    }
    deadline += timeout_ms;
    fd = connect_host("127.0.0.1", port, deadline);
    if (fd < 0 || !send_request(fd, "/status?pipeline=traces", deadline) ||
        !read_response(fd, response, max_response_bytes, &length, deadline)) {
        if (fd >= 0) {
            close(fd);
        }
        return EXIT_FAILURE;
    }
    close(fd);
    response[length] = '\0';
    separator = strstr(response, "\r\n\r\n");
    if (separator == NULL || !http_status_is_ok(response, length)) {
        return EXIT_FAILURE;
    }
    body = separator + 4;
    if (!response_is_healthy((const unsigned char *)body, length - (size_t)(body - response))) {
        return EXIT_FAILURE;
    }
    /* --port is a fixture-only seam; production also checks active targets. */
    if (test_seam || dependencies_are_healthy(deadline)) {
        return EXIT_SUCCESS;
    }
    return EXIT_FAILURE;
}
