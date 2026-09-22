/*
 * otel-probe/time_io.h — monotonic time, poll/timeout waits and non-blocking socket flags.
 *
 * Extracted verbatim from deploy/otel-health-probe.c by the
 * behavior-preserving module split in issue #46. This is a unity-build
 * fragment: it is included by deploy/otel-health-probe.c, which has already
 * included the standard headers and shared constants, and is never a
 * separate translation unit.
 */
#ifndef OTEL_PROBE_TIME_IO_H
#define OTEL_PROBE_TIME_IO_H

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
#endif /* OTEL_PROBE_TIME_IO_H */
