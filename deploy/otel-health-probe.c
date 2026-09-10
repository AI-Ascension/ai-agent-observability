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

static int64_t monotonic_millis(void) {
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 || now.tv_sec > INT64_MAX / 1000) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int wait_for(int fd, short events, int64_t deadline) {
    struct pollfd descriptor = {.fd = fd, .events = events, .revents = 0};
    int64_t now = monotonic_millis();
    int64_t remaining;
    int result;

    if (now < 0 || deadline <= now) {
        return 0;
    }
    remaining = deadline - now;
    if (remaining > INT32_MAX) {
        remaining = INT32_MAX;
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

static uint16_t read_u16(const unsigned char *buffer) {
    return (uint16_t)(((uint16_t)buffer[0] << 8) | buffer[1]);
}

/* Decode one DNS name to canonical lower-case wire form. */
static int dns_decode_name(const unsigned char *packet, size_t length, size_t *position,
                           unsigned char *name, size_t capacity, size_t *name_length) {
    size_t cursor = *position;
    size_t consumed = cursor;
    size_t output = 0;
    size_t labels = 0;
    int jumped = 0;

    while (cursor < length && labels++ < 128) {
        unsigned char label = packet[cursor++];

        if (label == 0) {
            if (output >= capacity) {
                return 0;
            }
            name[output++] = 0;
            *position = jumped ? consumed : cursor;
            *name_length = output;
            return 1;
        }
        if ((label & 0xc0) == 0xc0) {
            size_t target;

            if (cursor >= length) {
                return 0;
            }
            target = (size_t)(label & 0x3f) << 8 | packet[cursor];
            if (target >= length) {
                return 0;
            }
            if (!jumped) {
                consumed = cursor + 1;
                jumped = 1;
            }
            cursor = target;
            continue;
        }
        if ((label & 0xc0) != 0 || label > 63 || (size_t)label > length - cursor ||
            (size_t)label + 1 > capacity - output) {
            return 0;
        }
        name[output++] = label;
        for (size_t index = 0; index < label; ++index) {
            unsigned char character = packet[cursor + index];

            if (character >= 'A' && character <= 'Z') {
                character = (unsigned char)(character - 'A' + 'a');
            }
            name[output++] = character;
        }
        cursor += label;
    }
    return 0;
}

static int dns_names_equal(const unsigned char *left, size_t left_length,
                           const unsigned char *right, size_t right_length) {
    return left_length == right_length && memcmp(left, right, left_length) == 0;
}

struct dns_answer {
    unsigned char owner[max_dns_name_bytes];
    size_t owner_length;
    uint16_t type;
    uint16_t class;
    unsigned char target[max_dns_name_bytes];
    size_t target_length;
    unsigned char address[4];
    int has_target;
    int has_address;
};

static int dns_nameserver(struct sockaddr_in *nameserver) {
    char resolver[4096];
    size_t length = 0;
    int fd;

    if (dns_server[0] != '\0') {
        memset(nameserver, 0, sizeof(*nameserver));
        nameserver->sin_family = AF_INET;
        nameserver->sin_port = htons((uint16_t)dns_port);
        return inet_pton(AF_INET, dns_server, &nameserver->sin_addr) == 1;
    }

    fd = open("/etc/resolv.conf", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return 0;
    }
    while (length < sizeof(resolver)) {
        ssize_t count = read(fd, resolver + length, sizeof(resolver) - length);

        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return 0;
        }
        length += (size_t)count;
    }
    close(fd);
    if (length == sizeof(resolver)) {
        return 0;
    }
    for (size_t position = 0; position < length;) {
        size_t line_end = position;
        size_t word_start;
        size_t word_end;
        char address[INET_ADDRSTRLEN];

        while (line_end < length && resolver[line_end] != '\n') {
            ++line_end;
        }
        word_start = position;
        while (word_start < line_end && (resolver[word_start] == ' ' || resolver[word_start] == '\t')) {
            ++word_start;
        }
        if (line_end - word_start >= 10 && memcmp(resolver + word_start, "nameserver", 10) == 0 &&
            (word_start + 10 == line_end || resolver[word_start + 10] == ' ' ||
             resolver[word_start + 10] == '\t')) {
            word_start += 10;
            while (word_start < line_end && (resolver[word_start] == ' ' || resolver[word_start] == '\t')) {
                ++word_start;
            }
            word_end = word_start;
            while (word_end < line_end && resolver[word_end] != ' ' && resolver[word_end] != '\t' &&
                   resolver[word_end] != '\r' && resolver[word_end] != '#') {
                ++word_end;
            }
            if (word_end > word_start && word_end - word_start < sizeof(address)) {
                memcpy(address, resolver + word_start, word_end - word_start);
                address[word_end - word_start] = '\0';
                memset(nameserver, 0, sizeof(*nameserver));
                nameserver->sin_family = AF_INET;
                nameserver->sin_port = htons((uint16_t)dns_port);
                if (inet_pton(AF_INET, address, &nameserver->sin_addr) == 1) {
                    return 1;
                }
            }
        }
        position = line_end < length ? line_end + 1 : length;
    }
    return 0;
}

static int dns_qname(const char *host, unsigned char *packet, size_t capacity, size_t *position) {
    size_t host_position = 0;

    if (host[0] == '\0') {
        return 0;
    }
    while (host[host_position] != '\0') {
        size_t label_start = *position;
        size_t label_length = 0;

        if (*position + 1 >= capacity) {
            return 0;
        }
        ++*position;
        while (host[host_position] != '\0' && host[host_position] != '.') {
            if ((unsigned char)host[host_position] < 0x21 || host[host_position] > 0x7e ||
                label_length >= 63 || *position >= capacity) {
                return 0;
            }
            packet[(*position)++] = (unsigned char)host[host_position++];
            ++label_length;
        }
        if (label_length == 0) {
            return 0;
        }
        packet[label_start] = (unsigned char)label_length;
        if (host[host_position] == '.') {
            ++host_position;
        }
    }
    if (*position >= capacity) {
        return 0;
    }
    packet[(*position)++] = 0;
    return 1;
}

/* A tiny bounded IPv4 resolver avoids the NSS shared-library dependency of a static glibc binary. */
static int resolve_ipv4(const char *host, struct in_addr *address, int64_t deadline) {
    struct sockaddr_in nameserver;
    unsigned char query[512] = {0};
    unsigned char response[2048];
    unsigned char query_name[max_dns_name_bytes];
    struct dns_answer answers[max_dns_answers];
    struct sockaddr_in target;
    struct sockaddr_in responder;
    socklen_t responder_length;
    size_t position = 12;
    size_t query_qname_end;
    size_t query_name_length;
    size_t response_length;
    uint16_t query_id;
    uint16_t answer_count;
    uint16_t response_flags;
    int64_t now;
    int fd;

    if (inet_pton(AF_INET, host, address) == 1) {
        return 1;
    }
    if (!dns_nameserver(&nameserver)) {
        return 0;
    }
    if ((now = monotonic_millis()) < 0 || deadline <= now ||
        !dns_qname(host, query, sizeof(query), &position)) {
        return 0;
    }
    query_id = (uint16_t)((uint64_t)now ^ (uint64_t)getpid());
    query[0] = (unsigned char)(query_id >> 8);
    query[1] = (unsigned char)query_id;
    query[2] = 0x01; /* recursion desired */
    query[3] = 0x00;
    query[4] = 0x00;
    query[5] = 0x01;
    query_qname_end = position;
    query[position++] = 0x00;
    query[position++] = 0x01; /* QTYPE A */
    query[position++] = 0x00;
    query[position++] = 0x01; /* QCLASS IN */
    position = 12;
    if (!dns_decode_name(query, query_qname_end, &position, query_name, sizeof(query_name),
                         &query_name_length) || position != query_qname_end) {
        return 0;
    }
    position = query_qname_end + 4;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0 || !set_nonblocking(fd, 1)) {
        if (fd >= 0) {
            close(fd);
        }
        return 0;
    }
    memset(&target, 0, sizeof(target));
    target.sin_family = AF_INET;
    target.sin_port = nameserver.sin_port;
    target.sin_addr = nameserver.sin_addr;
    for (;;) {
        ssize_t count = sendto(fd, query, position, MSG_DONTWAIT,
                               (struct sockaddr *)&target, sizeof(target));

        if (count == (ssize_t)position) {
            break;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_for(fd, POLLOUT, deadline)) {
            continue;
        }
        close(fd);
        return 0;
    }
    response_length = 0;
    for (;;) {
        ssize_t count;

        if (!wait_for(fd, POLLIN, deadline)) {
            close(fd);
            return 0;
        }
        responder_length = sizeof(responder);
        count = recvfrom(fd, response, sizeof(response), 0,
                         (struct sockaddr *)&responder, &responder_length);
        if (count > 0) {
            if (responder.sin_family != AF_INET || responder.sin_port != nameserver.sin_port ||
                responder.sin_addr.s_addr != nameserver.sin_addr.s_addr) {
                close(fd);
                return 0;
            }
            response_length = (size_t)count;
            break;
        }
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        close(fd);
        return 0;
    }
    close(fd);
    if (response_length < 12) {
        return 0;
    }
    response_flags = read_u16(response + 2);
    answer_count = read_u16(response + 6);
    if (read_u16(response) != query_id || (response_flags & 0x8000) == 0 ||
        (response_flags & 0x0200) != 0 || (response_flags & 0x000f) != 0 ||
        read_u16(response + 4) != 1 || answer_count == 0 || answer_count > max_dns_answers) {
        return 0;
    }
    {
        unsigned char response_question[max_dns_name_bytes];
        size_t response_question_length;

        position = 12;
        if (!dns_decode_name(response, response_length, &position, response_question,
                             sizeof(response_question), &response_question_length) ||
            position + 4 > response_length ||
            !dns_names_equal(response_question, response_question_length, query_name,
                             query_name_length) ||
            read_u16(response + position) != 1 || read_u16(response + position + 2) != 1) {
            return 0;
        }
    }
    position += 4;
    for (uint16_t answer = 0; answer < answer_count; ++answer) {
        size_t data_position;
        size_t data_length;

        memset(&answers[answer], 0, sizeof(answers[answer]));
        if (!dns_decode_name(response, response_length, &position, answers[answer].owner,
                             sizeof(answers[answer].owner), &answers[answer].owner_length) ||
            position + 10 > response_length) {
            return 0;
        }
        answers[answer].type = read_u16(response + position);
        answers[answer].class = read_u16(response + position + 2);
        data_length = read_u16(response + position + 8);
        position += 10;
        if (data_length > response_length - position) {
            return 0;
        }
        data_position = position;
        if (answers[answer].class == 1 && answers[answer].type == 5) {
            if (!dns_decode_name(response, response_length, &data_position, answers[answer].target,
                                 sizeof(answers[answer].target), &answers[answer].target_length) ||
                data_position != position + data_length) {
                return 0;
            }
            answers[answer].has_target = 1;
        } else if (answers[answer].class == 1 && answers[answer].type == 1) {
            if (data_length != sizeof(answers[answer].address)) {
                return 0;
            }
            memcpy(answers[answer].address, response + position, sizeof(answers[answer].address));
            answers[answer].has_address = 1;
        }
        position += data_length;
    }
    {
        unsigned char current_name[max_dns_name_bytes];
        size_t current_length = query_name_length;

        memcpy(current_name, query_name, query_name_length);
        for (uint16_t step = 0; step < answer_count; ++step) {
            int cname_index = -1;
            int address_index = -1;

            for (uint16_t answer = 0; answer < answer_count; ++answer) {
                if (!dns_names_equal(answers[answer].owner, answers[answer].owner_length,
                                     current_name, current_length)) {
                    continue;
                }
                if (answers[answer].has_target) {
                    if (cname_index >= 0) {
                        return 0;
                    }
                    cname_index = (int)answer;
                } else if (answers[answer].has_address) {
                    if (address_index >= 0) {
                        return 0;
                    }
                    address_index = (int)answer;
                }
            }
            if (cname_index >= 0 && address_index >= 0) {
                return 0;
            }
            if (address_index >= 0) {
                memcpy(address, answers[address_index].address, sizeof(answers[address_index].address));
                return 1;
            }
            if (cname_index < 0 ||
                dns_names_equal(answers[cname_index].target, answers[cname_index].target_length,
                                current_name, current_length) ||
                answers[cname_index].target_length > sizeof(current_name)) {
                return 0;
            }
            memcpy(current_name, answers[cname_index].target, answers[cname_index].target_length);
            current_length = answers[cname_index].target_length;
        }
    }
    return 0;
}

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

static int read_collector_config(char *config, size_t capacity, size_t *length) {
    int fd = open(collector_config_path, O_RDONLY | O_CLOEXEC);
    size_t total = 0;

    if (fd < 0) {
        return 0;
    }
    while (total < capacity) {
        ssize_t count = read(fd, config + total, capacity - total);

        if (count == 0) {
            close(fd);
            *length = total;
            return 1;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return 0;
        }
        total += (size_t)count;
    }
    close(fd);
    return 0;
}

static int yaml_line(const char *config, size_t length, size_t *position, size_t *indent,
                     const char **content, size_t *content_length) {
    size_t line_start = *position;
    size_t line_end = line_start;
    size_t content_start;

    while (line_end < length && config[line_end] != '\n') {
        ++line_end;
    }
    content_start = line_start;
    *indent = 0;
    while (content_start < line_end && config[content_start] == ' ') {
        ++content_start;
        ++*indent;
    }
    if (content_start < line_end && config[content_start] == '\t') {
        return 0;
    }
    while (line_end > content_start &&
           (config[line_end - 1] == ' ' || config[line_end - 1] == '\r' ||
            config[line_end - 1] == '\t')) {
        --line_end;
    }
    *content = config + content_start;
    *content_length = line_end - content_start;
    *position = line_end < length ? line_end + 1 : length;
    return 1;
}

static int yaml_key(const char *content, size_t length, const char *key, const char **value,
                    size_t *value_length) {
    size_t key_length = strlen(key);
    size_t colon = 0;

    if (length == 0 || content[0] == '#') {
        return 0;
    }
    while (colon < length && content[colon] != ':') {
        ++colon;
    }
    if (colon != key_length || memcmp(content, key, key_length) != 0) {
        return 0;
    }
    ++colon;
    while (colon < length && (content[colon] == ' ' || content[colon] == '\t')) {
        ++colon;
    }
    *value = content + colon;
    *value_length = length - colon;
    return 1;
}

struct active_exporters {
    char names[max_active_exporters][max_exporter_name_bytes];
    size_t count;
};

struct exporter_target {
    char host[max_exporter_host_bytes];
    int port;
};

static int parse_port(const char *value, int *port);

static int exporter_token(const char *value, size_t length, struct active_exporters *active) {
    size_t start = 0;
    size_t end = length;

    while (start < end && (value[start] == ' ' || value[start] == '\t')) {
        ++start;
    }
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) {
        --end;
    }
    if (start < end && value[start] == '"' && value[end - 1] == '"') {
        ++start;
        --end;
    } else if (start < end && value[start] == '\'' && value[end - 1] == '\'') {
        ++start;
        --end;
    }
    if (start == end || end - start >= max_exporter_name_bytes) {
        return 0;
    }
    for (size_t index = 0; index < active->count; ++index) {
        if (end - start == strlen(active->names[index]) &&
            memcmp(value + start, active->names[index], end - start) == 0) {
            return 0;
        }
    }
    if (active->count >= max_active_exporters) {
        return 0;
    }
    memcpy(active->names[active->count], value + start, end - start);
    active->names[active->count][end - start] = '\0';
    ++active->count;
    return 1;
}

static int exporter_list(const char *value, size_t length, struct active_exporters *active) {
    size_t position;
    size_t token_start;
    int closed = 0;

    if (length < 2 || value[0] != '[' || value[length - 1] != ']') {
        return 0;
    }
    position = 1;
    while (position < length - 1) {
        while (position < length - 1 &&
               (value[position] == ' ' || value[position] == '\t' || value[position] == ',')) {
            ++position;
        }
        if (position >= length - 1) {
            break;
        }
        token_start = position;
        while (position < length - 1 && value[position] != ',') {
            ++position;
        }
        if (position == token_start || !exporter_token(value + token_start, position - token_start,
                                                        active)) {
            return 0;
        }
        if (position < length - 1) {
            ++position;
        } else {
            closed = 1;
        }
    }
    return closed || position == length - 1;
}

/* Extract only the service.pipelines.traces.exporters list. */
static int active_trace_exporters(const char *config, size_t length,
                                  struct active_exporters *active) {
    size_t position = 0;
    size_t service_indent = 0;
    size_t pipelines_indent = 0;
    size_t traces_indent = 0;
    size_t exporters_indent = 0;
    int in_service = 0;
    int in_pipelines = 0;
    int in_traces = 0;
    int in_exporters = 0;
    int multiline = 0;
    int found_exporters = 0;

    active->count = 0;
    while (position < length) {
        const char *content;
        size_t content_length;
        size_t indent;
        const char *value;
        size_t value_length;

        if (!yaml_line(config, length, &position, &indent, &content, &content_length)) {
            return 0;
        }
        if (content_length == 0 || content[0] == '#') {
            continue;
        }
        if (!in_service) {
            if (indent == 0 && yaml_key(content, content_length, "service", &value, &value_length)) {
                in_service = 1;
                service_indent = indent;
            }
            continue;
        }
        if (!in_pipelines) {
            if (indent <= service_indent) {
                continue;
            }
            if (yaml_key(content, content_length, "pipelines", &value, &value_length)) {
                in_pipelines = 1;
                pipelines_indent = indent;
            }
            continue;
        }
        if (!in_traces) {
            if (indent <= pipelines_indent) {
                continue;
            }
            if (yaml_key(content, content_length, "traces", &value, &value_length)) {
                in_traces = 1;
                traces_indent = indent;
            }
            continue;
        }
        if (!in_exporters) {
            if (indent <= traces_indent) {
                break;
            }
            if (yaml_key(content, content_length, "exporters", &value, &value_length)) {
                in_exporters = 1;
                found_exporters = 1;
                exporters_indent = indent;
                if (value_length == 0) {
                    multiline = 1;
                } else if (!exporter_list(value, value_length, active)) {
                    return 0;
                }
            }
            continue;
        }
        if (!multiline) {
            continue;
        }
        if (indent <= exporters_indent) {
            break;
        }
        if (content[0] != '-' || content_length < 2 ||
            !exporter_token(content + 1, content_length - 1, active)) {
            return 0;
        }
    }
    return found_exporters && active->count > 0;
}

static int yaml_mapping_name(const char *content, size_t length, char *name, size_t capacity,
                             size_t *name_length) {
    size_t colon = 0;
    size_t start = 0;
    size_t end;

    while (colon < length && content[colon] != ':') {
        ++colon;
    }
    if (colon == 0 || colon == length) {
        return 0;
    }
    end = colon;
    while (start < end && (content[start] == ' ' || content[start] == '\t')) {
        ++start;
    }
    while (end > start && (content[end - 1] == ' ' || content[end - 1] == '\t')) {
        --end;
    }
    if (start == end || end - start >= capacity) {
        return 0;
    }
    if ((content[start] == '"' && content[end - 1] == '"') ||
        (content[start] == '\'' && content[end - 1] == '\'')) {
        ++start;
        --end;
    }
    if (start == end || end - start >= capacity) {
        return 0;
    }
    memcpy(name, content + start, end - start);
    name[end - start] = '\0';
    if (name_length != NULL) {
        *name_length = end - start;
    }
    return 1;
}

static int parse_endpoint(const char *value, size_t length, struct exporter_target *target) {
    size_t start = 0;
    size_t end = length;
    size_t authority_end;
    size_t colon;
    char port_text[6];
    int port;

    while (start < end && (value[start] == ' ' || value[start] == '\t')) {
        ++start;
    }
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) {
        --end;
    }
    if (end - start >= 2 && ((value[start] == '"' && value[end - 1] == '"') ||
                             (value[start] == '\'' && value[end - 1] == '\''))) {
        ++start;
        --end;
    }
    if (end - start < strlen("http://") || memcmp(value + start, "http://", strlen("http://")) != 0) {
        return 0;
    }
    start += strlen("http://");
    authority_end = start;
    while (authority_end < end && value[authority_end] != '/') {
        ++authority_end;
    }
    if (authority_end == start || authority_end - start >= max_exporter_host_bytes ||
        memchr(value + start, '@', authority_end - start) != NULL) {
        return 0;
    }
    colon = authority_end;
    while (colon > start && value[colon - 1] != ':') {
        --colon;
    }
    if (colon == start) {
        return 0;
    }
    --colon;
    if (authority_end - colon - 1 == 0 || authority_end - colon - 1 >= sizeof(port_text)) {
        return 0;
    }
    memcpy(target->host, value + start, colon - start);
    target->host[colon - start] = '\0';
    memcpy(port_text, value + colon + 1, authority_end - colon - 1);
    port_text[authority_end - colon - 1] = '\0';
    if (!parse_port(port_text, &port)) {
        return 0;
    }
    target->port = port;
    return 1;
}

/* Read the endpoint from the named top-level exporter definition. */
static int exporter_endpoint(const char *config, size_t length, const char *name,
                             struct exporter_target *target) {
    size_t position = 0;
    size_t exporters_indent = 0;
    size_t target_indent = 0;
    int in_exporters = 0;
    int in_target = 0;
    int endpoint_seen = 0;

    while (position < length) {
        const char *content;
        size_t content_length;
        size_t indent;
        const char *value;
        size_t value_length;
        char mapping_name[max_exporter_name_bytes];

        if (!yaml_line(config, length, &position, &indent, &content, &content_length)) {
            return 0;
        }
        if (content_length == 0 || content[0] == '#') {
            continue;
        }
        if (!in_exporters) {
            if (indent == 0 && yaml_key(content, content_length, "exporters", &value, &value_length)) {
                in_exporters = 1;
                exporters_indent = indent;
            }
            continue;
        }
        if (indent <= exporters_indent) {
            break;
        }
        if (yaml_mapping_name(content, content_length, mapping_name, sizeof(mapping_name), NULL) &&
            indent == exporters_indent + 2) {
            in_target = strcmp(mapping_name, name) == 0;
            target_indent = indent;
            endpoint_seen = 0;
            continue;
        }
        if (in_target && indent == target_indent + 2 &&
            yaml_key(content, content_length, "endpoint", &value, &value_length)) {
            if (endpoint_seen || !parse_endpoint(value, value_length, target)) {
                return 0;
            }
            endpoint_seen = 1;
        }
    }
    return in_exporters && in_target && endpoint_seen;
}

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

static int json_space(unsigned char character) {
    return character == ' ' || character == '\t' || character == '\n' || character == '\r';
}

struct json_parser {
    const unsigned char *json;
    size_t length;
    size_t position;
};

static void json_skip_space(struct json_parser *parser) {
    while (parser->position < parser->length && json_space(parser->json[parser->position])) {
        ++parser->position;
    }
}

static int hex_digit(unsigned char character) {
    if (character >= '0' && character <= '9') {
        return (int)(character - '0');
    }
    if (character >= 'a' && character <= 'f') {
        return (int)(character - 'a' + 10);
    }
    if (character >= 'A' && character <= 'F') {
        return (int)(character - 'A' + 10);
    }
    return -1;
}

/* Parse an ASCII JSON string and optionally decode its bounded representation. */
static int json_string(struct json_parser *parser, char *value, size_t capacity, int *decoded) {
    size_t written = 0;
    int can_decode = 1;

    if (parser->position >= parser->length || parser->json[parser->position] != '"') {
        return 0;
    }
    ++parser->position;
    while (parser->position < parser->length) {
        unsigned char character = parser->json[parser->position++];
        unsigned int codepoint;

        if (character == '"') {
            if (value != NULL && capacity > 0) {
                if (written >= capacity) {
                    can_decode = 0;
                } else {
                    value[written] = '\0';
                }
            }
            if (decoded != NULL) {
                *decoded = can_decode;
            }
            return 1;
        }
        if (character < 0x20) {
            return 0;
        }
        if (character != '\\') {
            if (character >= 0x80) {
                return 0;
            }
            if (value != NULL && capacity > 0) {
                if (written + 1 >= capacity) {
                    can_decode = 0;
                } else {
                    value[written++] = (char)character;
                }
            }
            continue;
        }
        if (parser->position >= parser->length) {
            return 0;
        }
        character = parser->json[parser->position++];
        switch (character) {
        case '"':
        case '\\':
        case '/':
            codepoint = character;
            break;
        case 'b':
            codepoint = '\b';
            break;
        case 'f':
            codepoint = '\f';
            break;
        case 'n':
            codepoint = '\n';
            break;
        case 'r':
            codepoint = '\r';
            break;
        case 't':
            codepoint = '\t';
            break;
        case 'u': {
            int digit;

            codepoint = 0;
            for (int index = 0; index < 4; ++index) {
                if (parser->position >= parser->length ||
                    (digit = hex_digit(parser->json[parser->position++])) < 0) {
                    return 0;
                }
                codepoint = (codepoint << 4) | (unsigned int)digit;
            }
            if (codepoint > 0x7f) {
                return 0;
            }
            break;
        }
        default:
            return 0;
        }
        if (value != NULL && capacity > 0) {
            if (written + 1 >= capacity) {
                can_decode = 0;
            } else {
                value[written++] = (char)codepoint;
            }
        }
    }
    return 0;
}

static int json_literal(struct json_parser *parser, const char *literal) {
    size_t length = strlen(literal);

    if (length > parser->length - parser->position ||
        memcmp(parser->json + parser->position, literal, length) != 0) {
        return 0;
    }
    parser->position += length;
    return 1;
}

static int json_number(struct json_parser *parser) {
    size_t start = parser->position;

    if (parser->position < parser->length && parser->json[parser->position] == '-') {
        ++parser->position;
    }
    if (parser->position >= parser->length) {
        return 0;
    }
    if (parser->json[parser->position] == '0') {
        ++parser->position;
    } else if (parser->json[parser->position] >= '1' && parser->json[parser->position] <= '9') {
        do {
            ++parser->position;
        } while (parser->position < parser->length && parser->json[parser->position] >= '0' &&
                 parser->json[parser->position] <= '9');
    } else {
        return 0;
    }
    if (parser->position < parser->length && parser->json[parser->position] == '.') {
        ++parser->position;
        if (parser->position >= parser->length || parser->json[parser->position] < '0' ||
            parser->json[parser->position] > '9') {
            return 0;
        }
        do {
            ++parser->position;
        } while (parser->position < parser->length && parser->json[parser->position] >= '0' &&
                 parser->json[parser->position] <= '9');
    }
    if (parser->position < parser->length &&
        (parser->json[parser->position] == 'e' || parser->json[parser->position] == 'E')) {
        ++parser->position;
        if (parser->position < parser->length &&
            (parser->json[parser->position] == '+' || parser->json[parser->position] == '-')) {
            ++parser->position;
        }
        if (parser->position >= parser->length || parser->json[parser->position] < '0' ||
            parser->json[parser->position] > '9') {
            return 0;
        }
        do {
            ++parser->position;
        } while (parser->position < parser->length && parser->json[parser->position] >= '0' &&
                 parser->json[parser->position] <= '9');
    }
    return parser->position > start;
}

static int json_value(struct json_parser *parser, int depth);

static int json_object_generic(struct json_parser *parser, int depth) {
    char keys[max_object_members][max_json_string_bytes];
    size_t members = 0;

    if (depth > max_json_depth || parser->position >= parser->length ||
        parser->json[parser->position++] != '{') {
        return 0;
    }
    json_skip_space(parser);
    if (parser->position < parser->length && parser->json[parser->position] == '}') {
        ++parser->position;
        return 1;
    }
    for (;;) {
        char key[max_json_string_bytes];
        int decoded;

        if (members >= max_object_members || !json_string(parser, key, sizeof(key), &decoded) || !decoded) {
            return 0;
        }
        for (size_t index = 0; index < members; ++index) {
            if (strcmp(keys[index], key) == 0) {
                return 0;
            }
        }
        memcpy(keys[members++], key, sizeof(key));
        json_skip_space(parser);
        if (parser->position >= parser->length || parser->json[parser->position++] != ':') {
            return 0;
        }
        json_skip_space(parser);
        if (!json_value(parser, depth + 1)) {
            return 0;
        }
        json_skip_space(parser);
        if (parser->position >= parser->length) {
            return 0;
        }
        if (parser->json[parser->position] == '}') {
            ++parser->position;
            return 1;
        }
        if (parser->json[parser->position++] != ',') {
            return 0;
        }
        json_skip_space(parser);
        if (parser->position >= parser->length || parser->json[parser->position] == '}') {
            return 0;
        }
    }
}

static int json_array(struct json_parser *parser, int depth) {
    size_t elements = 0;

    if (depth > max_json_depth || parser->position >= parser->length ||
        parser->json[parser->position++] != '[') {
        return 0;
    }
    json_skip_space(parser);
    if (parser->position < parser->length && parser->json[parser->position] == ']') {
        ++parser->position;
        return 1;
    }
    for (;;) {
        if (elements++ >= max_array_elements || !json_value(parser, depth + 1)) {
            return 0;
        }
        json_skip_space(parser);
        if (parser->position >= parser->length) {
            return 0;
        }
        if (parser->json[parser->position] == ']') {
            ++parser->position;
            return 1;
        }
        if (parser->json[parser->position++] != ',') {
            return 0;
        }
        json_skip_space(parser);
        if (parser->position >= parser->length || parser->json[parser->position] == ']') {
            return 0;
        }
    }
}

static int json_value(struct json_parser *parser, int depth) {
    unsigned char character;

    json_skip_space(parser);
    if (parser->position >= parser->length) {
        return 0;
    }
    character = parser->json[parser->position];
    if (character == '"') {
        return json_string(parser, NULL, 0, NULL);
    }
    if (character == '{') {
        return json_object_generic(parser, depth);
    }
    if (character == '[') {
        return json_array(parser, depth);
    }
    if (character == 't') {
        return json_literal(parser, "true");
    }
    if (character == 'f') {
        return json_literal(parser, "false");
    }
    if (character == 'n') {
        return json_literal(parser, "null");
    }
    if (character == '-' || (character >= '0' && character <= '9')) {
        return json_number(parser);
    }
    return 0;
}

static int json_health_object(struct json_parser *parser, int *healthy, int *status_ok,
                              int *healthy_seen, int *status_seen) {
    char keys[max_object_members][max_json_string_bytes];
    size_t members = 0;

    if (parser->position >= parser->length || parser->json[parser->position++] != '{') {
        return 0;
    }
    json_skip_space(parser);
    if (parser->position < parser->length && parser->json[parser->position] == '}') {
        ++parser->position;
        return 1;
    }
    for (;;) {
        char key[max_json_string_bytes];
        int decoded;

        if (members >= max_object_members || !json_string(parser, key, sizeof(key), &decoded) || !decoded) {
            return 0;
        }
        for (size_t index = 0; index < members; ++index) {
            if (strcmp(keys[index], key) == 0) {
                return 0;
            }
        }
        memcpy(keys[members++], key, sizeof(key));
        json_skip_space(parser);
        if (parser->position >= parser->length || parser->json[parser->position++] != ':') {
            return 0;
        }
        json_skip_space(parser);
        if (strcmp(key, "healthy") == 0) {
            if (!json_literal(parser, "true")) {
                return 0;
            }
            *healthy_seen = 1;
            *healthy = 1;
        } else if (strcmp(key, "status") == 0) {
            char status[max_json_string_bytes];
            int status_decoded;

            if (!json_string(parser, status, sizeof(status), &status_decoded)) {
                return 0;
            }
            *status_seen = 1;
            // v0.160's component-status extension reports recoverable errors
            // as healthy during recovery_duration. Accept that explicit state
            // while continuing to reject starting, permanent, or unknown states.
            *status_ok = status_decoded &&
                (strcmp(status, "StatusOK") == 0 ||
                 strcmp(status, "StatusRecoverableError") == 0);
        } else if (!json_value(parser, 1)) {
            return 0;
        }
        json_skip_space(parser);
        if (parser->position >= parser->length) {
            return 0;
        }
        if (parser->json[parser->position] == '}') {
            ++parser->position;
            return 1;
        }
        if (parser->json[parser->position++] != ',') {
            return 0;
        }
        json_skip_space(parser);
        if (parser->position >= parser->length || parser->json[parser->position] == '}') {
            return 0;
        }
    }
}

static int response_is_healthy(const unsigned char *body, size_t length) {
    struct json_parser parser = {.json = body, .length = length, .position = 0};
    int healthy = 0;
    int status_ok = 0;
    int healthy_seen = 0;
    int status_seen = 0;

    json_skip_space(&parser);
    if (!json_health_object(&parser, &healthy, &status_ok, &healthy_seen, &status_seen)) {
        return 0;
    }
    json_skip_space(&parser);
    return parser.position == length && healthy_seen && status_seen && healthy && status_ok;
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
