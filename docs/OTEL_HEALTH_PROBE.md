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
and has one two-second monotonic deadline shared by connection, write, read,
DNS, and downstream checks. Any connection, HTTP, JSON, health,
pipeline-status, or deadline failure exits nonzero without printing response
content. `--port` is a loopback-only test seam; the runtime healthcheck does
not pass it.

In production mode the probe also reads the read-only Collector configuration
and extracts only `service.pipelines.traces.exporters`. For every active
exporter it reads the actual `http://host:port` endpoint from that exporter's
top-level definition and checks the corresponding service's `/health` URL;
the probe does not carry a separate host or port map that can drift from the
mounted configuration. Missing definitions, unsupported endpoint forms,
malformed configuration, DNS failures, unrelated DNS answers, duplicate
A/CNAME records, and unresolved or looping CNAME chains fail closed. The
native resolver validates the DNS transaction ID, responder address, question
name/type/class, canonical owner names, and bounded answer chain so a valid A
record for another name cannot satisfy the check.

`deploy/install-otel-health-probe.sh --check` is a read-only owner-side
preflight. Installation requires explicit source/config/Compose/Dockerfile
and image identity hashes, a clean probe build input set,
`OTEL_HEALTH_PROBE_INSTALL_APPROVED=true`, and an operator quiescence record
through `OTEL_QUIESCE_APPROVED=true`. It compares the exact active traces
exporter set, rendered Compose image reference, bind source/destination/RO
mode, mounted config hash, and intended Collector environment before making a
fresh verified backup. The complete pre-update environment is retained only as
a digest and is required to match after recreation; the inspect backup removes
environment values and command arguments. It then builds and verifies the
wrapper image, recreates only `otel-collector`, waits for its health state, and
verifies the same identities afterward under one aggregate installation
deadline (`OTEL_INSTALL_TIMEOUT_SECONDS`, 1200 seconds by default). If the
guarded operation fails it retags the prior image and recreates the same
service only when every bounded rollback step can be checked. Each rollback
phase records a status in a mode-0600 private log; otherwise it reports
rollback as unknown and requires manual reconciliation. It never uses
project-wide down, volume deletion, or image pruning.

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
