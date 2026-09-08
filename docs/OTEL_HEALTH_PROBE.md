# Collector health probe

The `otel-collector` service uses the OpenTelemetry Collector Contrib 0.160.0
component-status health implementation. The health endpoint is configured by
`deploy/otel-collector.yaml` as `127.0.0.1:13133/status` inside the container;
it is not published on a host port and it is not reachable through the OTLP
listener.

The Compose command enables
`extension.healthcheck.useComponentStatus`. This is required for the v2
`http` and `component_health` fields in the pinned 0.160.0 extension. The
deprecated `check_collector_pipeline` setting is deliberately not used because
the upstream extension documents that behavior as broken. Recoverable and
permanent component errors are included, with a 30-second recovery window for
recoverable errors. The traces pipeline status remains visible through the
endpoint's pipeline query.

The image is a small wrapper around the same upstream Collector image. A static
C probe is compiled in a disposable GCC builder stage and copied into the
distroless runtime at `/usr/local/bin/otel-health-probe`; the runtime image
does not need curl, a shell, or a dynamically linked library. The probe's
production invocation has no arguments and performs this bounded request:

```text
GET /status?pipeline=traces HTTP/1.1
Host: localhost
Connection: close
Accept: application/json
```

It succeeds only when the endpoint returns HTTP 200 and the top-level JSON
fields report `healthy: true` and `status: "StatusOK"`. It reads at most 8 KiB
and has a two-second connection, write, and read deadline. Any connection,
HTTP, JSON, health, pipeline-status, or deadline failure exits nonzero without
printing response content. `--port` is a loopback-only test seam; the runtime
healthcheck does not pass it.

The image and Compose healthcheck use a 30-second interval, five-second engine
timeout, 30-second startup grace, and three retries. Podman 4.9.3 cannot add a
healthcheck to an existing container in place, so a deployment owner must
target only this service for recreation after building the wrapper image. The
existing config bind, ports, OTLP exporters, and persistent data owned by the
rest of the stack remain unchanged. A rollback restores the prior image and
collector config, then recreates only this service after preserving the exact
old container identity and source/runtime evidence.

This source change proves configuration, image build inputs, and probe
semantics. It does not claim live health, recurring timer execution, display
rendering, or persistence until the serialized Train deployment records those
separately.
