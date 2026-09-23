/*
 * otel-probe/config.h — read-only Collector config loading and bounded YAML line/key scanning.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_CONFIG_H
#define OTEL_PROBE_CONFIG_H

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

#endif /* OTEL_PROBE_CONFIG_H */
