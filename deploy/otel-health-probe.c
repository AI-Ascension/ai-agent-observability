/*
 * A small, dependency-free healthcheck for the distroless Collector image.
 *
 * The production invocation intentionally has no arguments.  --port is kept
 * as a loopback-only test seam so the source test can exercise positive,
 * negative, and timeout responses without changing the runtime contract.
 */
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
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

enum {
    default_port = 13133,
    timeout_ms = 2000,
    max_response_bytes = 8192,
    max_json_string_bytes = 64,
};

static int64_t monotonic_millis(void) {
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int wait_for(int fd, short events, int64_t deadline) {
    struct pollfd descriptor = {.fd = fd, .events = events, .revents = 0};
    int64_t remaining = deadline - monotonic_millis();
    int result;

    if (remaining <= 0 || remaining > INT32_MAX) {
        return 0;
    }
    do {
        result = poll(&descriptor, 1, (int)remaining);
    } while (result < 0 && errno == EINTR);
    if (result != 1 || (descriptor.revents & (events | POLLERR | POLLHUP)) == 0) {
        return 0;
    }
    return 1;
}

static int set_nonblocking(int fd, int enabled) {
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags < 0) {
        return 0;
    }
    if (enabled) {
        flags |= O_NONBLOCK;
    } else {
        flags &= ~O_NONBLOCK;
    }
    return fcntl(fd, F_SETFL, flags) == 0;
}

static int connect_loopback(int port, int64_t deadline) {
    struct sockaddr_in address = {0};
    int fd;
    int error = 0;
    socklen_t error_length = sizeof(error);

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0 || !set_nonblocking(fd, 1)) {
        if (fd >= 0) {
            close(fd);
        }
        return -1;
    }
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        return fd;
    }
    if (errno != EINPROGRESS || !wait_for(fd, POLLOUT, deadline) ||
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_length) != 0 || error != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int send_request(int fd, int64_t deadline) {
    static const char request[] =
        "GET /status?pipeline=traces HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Connection: close\r\n"
        "Accept: application/json\r\n\r\n";
    size_t sent = 0;

    while (sent < sizeof(request) - 1) {
        ssize_t count;

        if (!wait_for(fd, POLLOUT, deadline)) {
            return 0;
        }
        count = send(fd, request + sent, sizeof(request) - 1 - sent, MSG_NOSIGNAL);
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

static void skip_space(const char *json, size_t length, size_t *position) {
    while (*position < length && isspace((unsigned char)json[*position])) {
        ++*position;
    }
}

static int read_string(const char *json, size_t length, size_t *position, char *value, size_t capacity) {
    size_t written = 0;

    if (*position >= length || json[*position] != '"') {
        return 0;
    }
    ++*position;
    while (*position < length) {
        unsigned char character = (unsigned char)json[*position];

        if (character == '"') {
            ++*position;
            if (written >= capacity) {
                return 0;
            }
            value[written] = '\0';
            return 1;
        }
        if (character == '\\' || character < 0x20 || written + 1 >= capacity) {
            return 0;
        }
        value[written++] = (char)character;
        ++*position;
    }
    return 0;
}

static int skip_value(const char *json, size_t length, size_t *position) {
    size_t start = *position;
    int depth = 0;
    int in_string = 0;
    int escaped = 0;

    while (*position < length) {
        char character = json[*position];

        if (in_string) {
            if (escaped) {
                escaped = 0;
            } else if (character == '\\') {
                escaped = 1;
            } else if (character == '"') {
                in_string = 0;
            }
        } else if (character == '"') {
            in_string = 1;
        } else if (character == '{' || character == '[') {
            ++depth;
        } else if (character == '}' || character == ']') {
            if (depth == 0) {
                break;
            }
            --depth;
        } else if (depth == 0 && (character == ',' || isspace((unsigned char)character))) {
            break;
        }
        ++*position;
        if (depth == 0 && *position > start && in_string == 0 &&
            (*position == length || json[*position] == ',' || json[*position] == '}')) {
            break;
        }
    }
    return *position > start;
}

static int response_is_healthy(const char *body, size_t length) {
    size_t position = 0;
    int healthy = 0;
    int status_ok = 0;
    char key[32];
    char value[max_json_string_bytes];

    skip_space(body, length, &position);
    if (position >= length || body[position++] != '{') {
        return 0;
    }
    for (;;) {
        skip_space(body, length, &position);
        if (position < length && body[position] == '}') {
            return healthy && status_ok;
        }
        if (!read_string(body, length, &position, key, sizeof(key))) {
            return 0;
        }
        skip_space(body, length, &position);
        if (position >= length || body[position++] != ':') {
            return 0;
        }
        skip_space(body, length, &position);
        if (strcmp(key, "healthy") == 0) {
            if (position + 4 > length || memcmp(body + position, "true", 4) != 0) {
                return 0;
            }
            position += 4;
            healthy = 1;
        } else if (strcmp(key, "status") == 0) {
            if (!read_string(body, length, &position, value, sizeof(value))) {
                return 0;
            }
            status_ok = strcmp(value, "StatusOK") == 0;
        } else if (!skip_value(body, length, &position)) {
            return 0;
        }
        skip_space(body, length, &position);
        if (position >= length || (body[position] != ',' && body[position] != '}')) {
            return 0;
        }
        if (body[position++] == '}') {
            return healthy && status_ok;
        }
    }
}

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
    int fd;
    int64_t deadline;
    char response[max_response_bytes + 1];
    size_t length;
    char *body;
    char *separator;
    int result = EXIT_FAILURE;

    if (argc == 3 && strcmp(argv[1], "--port") == 0) {
        if (!parse_port(argv[2], &port)) {
            return 2;
        }
    } else if (argc != 1) {
        (void)fprintf(stderr, "usage: %s [--port LOOPBACK_PORT]\n", argv[0]);
        return 2;
    }
    deadline = monotonic_millis();
    if (deadline < 0) {
        return EXIT_FAILURE;
    }
    deadline += timeout_ms;
    fd = connect_loopback(port, deadline);
    if (fd < 0 || !send_request(fd, deadline) || !read_response(fd, response, max_response_bytes, &length, deadline)) {
        if (fd >= 0) {
            close(fd);
        }
        return EXIT_FAILURE;
    }
    close(fd);
    response[length] = '\0';
    separator = strstr(response, "\r\n\r\n");
    if (separator == NULL || strncmp(response, "HTTP/1.1 200 ", 13) != 0) {
        return EXIT_FAILURE;
    }
    body = separator + 4;
    if (response_is_healthy(body, length - (size_t)(body - response))) {
        result = EXIT_SUCCESS;
    }
    return result;
}
