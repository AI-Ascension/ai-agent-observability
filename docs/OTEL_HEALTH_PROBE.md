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
does not need curl, a shell, or a dynamically linked library. The same builder
stage creates `/var/lib/otelcol/file_storage` with ownership `10001:10001`, so
an empty named volume inherits a writable directory for the non-root Collector
user. The probe's
production invocation has no arguments and performs this bounded request:

```text
GET /status?pipeline=traces HTTP/1.1
Host: localhost
Connection: close
Accept: application/json
```

It succeeds only when the endpoint returns HTTP 200 and the top-level JSON
fields report `healthy: true` and status `"StatusOK"` or
`"StatusRecoverableError"`. The latter is accepted only for the configured
30-second recoverable-error window; starting, permanent, and unknown statuses
remain failures. It reads at most 8 KiB
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
`OTEL_HEALTH_PROBE_INSTALL_APPROVED=true`, and an operator approval through
`OTEL_QUIESCE_APPROVED=true` plus a fresh `OTEL_QUIESCE_PROOF` JSON record. The
approval records intent and binds the target to the current Collector
container; it does not claim that producers have already drained. The installer
then observes the running Collector's Prometheus endpoint at
`OTEL_METRICS_URL` (the configured loopback-published
`http://127.0.0.1:${OTEL_METRICS_PORT}/metrics` endpoint) for the configured
`OTEL_QUIESCE_OBSERVATION_SECONDS` interval, which defaults to five seconds.
An override is accepted only when it is that exact loopback URL.
It requires queue and in-flight request series, requires their values to remain
zero, and requires `otelcol_receiver_accepted_spans` to remain unchanged over
the complete interval. It performs this live observation before the build and
again immediately before service recreation, after rechecking the container
identity, so a stale approval cannot substitute for current runtime evidence.

The approval file has this schema:

```json
{
  "schema": "otel-quiescence-approval-v1",
  "approved": true,
  "project": "ai-agent-observability",
  "service": "otel-collector",
  "container": "ai-agent-observability-otel-collector",
  "container_id": "<current-container-id>",
  "approved_at_utc": "2026-09-08T20:00:00Z"
}
```

Pass its path as `OTEL_QUIESCE_PROOF`; the installer rejects stale records and
identity mismatches. The live metrics observer rejects missing series, nonzero
queues or in-flight requests, changing accepted-span counters, malformed
Prometheus samples, non-finite values, and an unavailable endpoint. Its
machine-readable result is retained in the private installation backup.

The installer compares the exact active traces exporter and receiver sets,
rendered Compose image reference, bind source/destination/RO mode, mounted
config hash, intended Collector environment, and the exact writable
`ai-agent-observability-otel-collector-queue-data` volume mount before making a
fresh verified backup. The owner supplies `OTEL_EXPECTED_TRACE_EXPORTERS`,
`OTEL_EXPECTED_TRACE_RECEIVERS`, and
`OTEL_EXPECTED_TRACE_RECEIVER_SERIES`; empty, duplicate, malformed, missing,
or unexpected values fail closed. The live observer requires exactly one queue
and one in-flight series for every expected exporter, and exactly one accepted
span series for every expected `receiver/transport` pair. Duplicate labels,
malformed samples, negative counters, and unrelated receiver or exporter
series are rejected. The observer also requires that the active container
inspect maps `8888/tcp` exactly to `127.0.0.1:${OTEL_METRICS_PORT}` before it
uses the host endpoint, so an unrelated loopback listener cannot satisfy the
quiescence gate.

The complete pre-update environment is retained only as a digest and is
required to match after recreation; the inspect backup removes environment
values and command arguments. The runtime identity digest also covers the
command, entrypoint, exposed and published ports, network aliases, devices,
resource limits, security settings, and mounts. After the image build and
again immediately before recreation, the installer rechecks the active
container's image, state, exact health contract, mounted config, environment,
runtime identity, metrics binding, and reviewed source hashes. It then builds
and verifies the wrapper image, recreates only `otel-collector`, waits for its
health state, and verifies the same identities afterward under one aggregate
installation deadline (`OTEL_INSTALL_TIMEOUT_SECONDS`, 1200 seconds by
default). The deadline includes every inspector and readiness wait; bounded
commands reserve their process-kill grace instead of adding it after expiry.
If the image build fails, the prior image tag is restored while the active
Collector is left untouched because runtime mutation has not begun. If a later
runtime mutation fails, the installer retags the prior image and recreates the
same service only when every bounded rollback step can be checked. Rollback has
its own aggregate deadline (`OTEL_ROLLBACK_TIMEOUT_SECONDS`, 600 seconds by
default) so a nearly exhausted install budget cannot make compensation
unbounded. Each rollback phase records a status in a mode-0600 private log;
otherwise it reports rollback as unknown and requires manual reconciliation. It
never uses project-wide down, volume deletion, or image pruning.

The live deployment path is currently a non-Git tree. Before copying a reviewed
checkout there, run `deploy/materialize-otel-source.sh --materialize` with
`OTEL_SOURCE_MATERIALIZE_APPROVED=true`, an external
`OTEL_MATERIALIZATION_BACKUP_ROOT`, and the exact
`OTEL_EXPECTED_GIT_HEAD`. The helper archives the complete original tree,
records source modes and bind-source device/inode identities, writes reviewed
files in place, and leaves the existing `.env` untouched. It does not replace
the deployment directory, because replacing a bind-source file or directory
can leave an already-mounted inode pinned to the old content. The generated
`deploy/.otel-source-manifest.json` lets the installer admit the non-Git tree
only when every reviewed source hash and mode matches. If installation later
fails, set `OTEL_MATERIALIZATION_BACKUP_DIR` to that external capture; the
installer restores the original tree and verifies its bytes, modes, and bind
inodes before attempting service compensation. The helper's explicit
`--rollback` path uses the same checks for a source-only rollback.

The image and Compose healthcheck use the exact reviewed contract
`CMD ["/usr/local/bin/otel-health-probe"]`, a 30-second interval, five-second
engine timeout, 30-second startup grace, and three retries. Podman 4.9.3 cannot add a
healthcheck to an existing container in place, so a deployment owner must
target only this service for recreation after building the wrapper image. The
existing config bind, ports, OTLP exporters, and persistent data owned by the
rest of the stack remain unchanged. A rollback restores the prior image and
collector config, then recreates only this service after preserving the exact
old container identity and source/runtime evidence. The Collector queue
volume is deliberately retained across that recreation; do not use `down -v`.

This source change proves configuration, image build inputs, and probe
semantics. It does not claim live health, recurring timer execution, display
rendering, or persistence until the serialized Train deployment records those
separately.
