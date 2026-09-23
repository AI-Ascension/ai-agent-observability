/*
 * otel-probe/exporters.h — active traces-exporter parsing and exporter endpoint extraction.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_EXPORTERS_H
#define OTEL_PROBE_EXPORTERS_H

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
    int target_seen = 0;
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
            if (in_target) {
                /* Preserve the selected endpoint when later sibling exporters
                 * are read; a repeated definition is still ambiguous. */
                if (target_seen) {
                    return 0;
                }
                target_seen = 1;
                target_indent = indent;
            }
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
    return in_exporters && target_seen && endpoint_seen;
}

#endif /* OTEL_PROBE_EXPORTERS_H */
