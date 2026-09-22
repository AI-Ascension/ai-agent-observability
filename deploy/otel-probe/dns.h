/*
 * otel-probe/dns.h — bounded static DNS resolver: name decoding, nameserver discovery, qname, A/CNAME chain validation.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_DNS_H
#define OTEL_PROBE_DNS_H

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

#endif /* OTEL_PROBE_DNS_H */
