/*
 * otel-probe/http.h — TCP connect, bounded HTTP request/response and status/endpoint helpers.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_HTTP_H
#define OTEL_PROBE_HTTP_H

static int connect_host(const char *host, int port, int64_t deadline) {
    struct sockaddr_in address = {0};
    int error = 0;
    socklen_t error_length = sizeof(error);
    int fd;

    if (port < 1 || port > 65535 || !resolve_ipv4(host, &address.sin_addr, deadline)) {
        return -1;
    }
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0 || !set_nonblocking(fd, 1)) {
        if (fd >= 0) {
            close(fd);
        }
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        return fd;
    }
    if (errno == EINPROGRESS && wait_for(fd, POLLOUT, deadline) &&
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_length) == 0 && error == 0) {
        return fd;
    }
    close(fd);
    return -1;
}

static int send_request(int fd, const char *path, int64_t deadline) {
    char request[256];
    int request_length;
    size_t sent = 0;

    request_length = snprintf(request, sizeof(request),
                              "GET %s HTTP/1.1\r\n"
                              "Host: localhost\r\n"
                              "Connection: close\r\n"
                              "Accept: application/json\r\n\r\n",
                              path);
    if (request_length <= 0 || (size_t)request_length >= sizeof(request)) {
        return 0;
    }
    while (sent < (size_t)request_length) {
        ssize_t count;

        if (!wait_for(fd, POLLOUT, deadline)) {
            return 0;
        }
        count = send(fd, request + sent, (size_t)request_length - sent, MSG_NOSIGNAL);
        if (count > 0) {
            sent += (size_t)count;
        } else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            return 0;
        }
    }
    return 1;
}

static int read_response(int fd, char *response, size_t capacity, size_t *length, int64_t deadline) {
    *length = 0;
    for (;;) {
        ssize_t count;

        if (!wait_for(fd, POLLIN, deadline)) {
            return 0;
        }
        count = recv(fd, response + *length, capacity - *length, 0);
        if (count == 0) {
            return 1;
        }
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            return 0;
        }
        *length += (size_t)count;
        if (*length == capacity) {
            return 0;
        }
        response[*length] = '\0';
    }
}

static int http_status_is_ok(const char *response, size_t length) {
    return length >= 13 && memcmp(response, "HTTP/1.", 7) == 0 && response[8] == ' ' &&
           response[9] == '2' && response[10] == '0' && response[11] == '0' &&
           response[12] == ' ';
}

/* Downstream /health endpoints are liveness endpoints; HTTP 200 is their contract. */
static int http_endpoint_is_healthy(const char *host, int port, const char *path, int64_t deadline) {
    int fd;
    char response[max_response_bytes + 1];
    size_t length;

    if (deadline <= monotonic_millis()) {
        return 0;
    }
    fd = connect_host(host, port, deadline);
    if (fd < 0 || !send_request(fd, path, deadline) ||
        !read_response(fd, response, max_response_bytes, &length, deadline)) {
        if (fd >= 0) {
            close(fd);
        }
        return 0;
    }
    close(fd);
    response[length] = '\0';
    return http_status_is_ok(response, length);
}

#endif /* OTEL_PROBE_HTTP_H */
