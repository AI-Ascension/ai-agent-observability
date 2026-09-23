/*
 * otel-probe/json.h — strict bounded JSON parsing and Collector health-response evaluation.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_JSON_H
#define OTEL_PROBE_JSON_H

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

#endif /* OTEL_PROBE_JSON_H */
