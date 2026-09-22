#!/usr/bin/env bash
# OTel installer quiescence helpers — operator approval validation and live metrics observation
#
# Extracted verbatim from deploy/install-otel-health-probe.sh by the
# behavior-preserving module split in issue #45. This file is sourced by the
# installer coordinator and defines functions only; it is never executed
# directly.
#
# ShellCheck cannot follow the coordinator's `source` chain, so shared
# globals and helper functions appear "unused" or "unassigned" per file.
# The two diagnostics below are disabled file-wide for that reason.
# shellcheck disable=SC2034,SC2154

verify_quiescence_approval() {
  local proof="$1"
  local expected_id="$2"
  [[ -f "$proof" ]] || fail 'OTEL_QUIESCE_PROOF must name a fresh approval file'
  python3 - "$proof" "$project_name" "$container_name" "$expected_id" \
    "${OTEL_QUIESCE_MAX_AGE_SECONDS:-120}" <<'PY'
import datetime as dt
import json
import sys
from pathlib import Path

path, project, container, expected_id, max_age_text = sys.argv[1:]
try:
    max_age = int(max_age_text)
except ValueError:
    raise SystemExit("OTEL_QUIESCE_MAX_AGE_SECONDS must be an integer")
if max_age < 5 or max_age > 3600:
    raise SystemExit("OTEL_QUIESCE_MAX_AGE_SECONDS is outside 5..3600")
try:
    proof = json.loads(Path(path).read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"quiescence approval is not valid JSON: {exc}")
if proof.get("schema") != "otel-quiescence-approval-v1":
    raise SystemExit("quiescence approval schema is invalid")
if proof.get("approved") is not True:
    raise SystemExit("quiescence approval is not approved")
if proof.get("project") != project or proof.get("service") != "otel-collector":
    raise SystemExit("quiescence approval target does not match the reviewed service")
if proof.get("container") != container or proof.get("container_id") != expected_id:
    raise SystemExit("quiescence approval container identity does not match the active container")
try:
    stamp = dt.datetime.fromisoformat(str(proof["approved_at_utc"]).replace("Z", "+00:00"))
except Exception as exc:
    raise SystemExit(f"quiescence approval timestamp is invalid: {exc}")
if stamp.tzinfo is None:
    raise SystemExit("quiescence approval timestamp has no timezone")
age = (dt.datetime.now(dt.timezone.utc) - stamp.astimezone(dt.timezone.utc)).total_seconds()
if age < -5 or age > max_age:
    raise SystemExit(f"quiescence approval is stale or from the future (age={age:.3f}s max_age={max_age}s)")
PY
}
# The approval file records operator intent only. Quiescence is established by
# this read-only observer against the running Collector's Prometheus endpoint:
# every exporter queue and in-flight request must be zero, and the accepted
# span counter must remain unchanged over the complete bounded interval.
observe_live_quiescence() {
  local label="$1"
  local requested="$2"
  # The requested interval is the observation window itself. Allow a bounded
  # margin for the initial/final HTTP samples so the outer timeout cannot kill
  # a valid five-second observation at its deadline.
  bounded_capture "$label" "$((requested + 5))" python3 - "$metrics_url" \
    "$quiesce_observation_seconds" "$expected_exporters_canonical" \
    "$expected_receiver_series_canonical" <<'PY'
import json
import math
import re
import sys
import time
import urllib.error
import urllib.request

url, duration_text, expected_exporters_text, expected_receiver_series_text = sys.argv[1:]
try:
    duration = int(duration_text)
except ValueError:
    raise SystemExit("OTEL_QUIESCE_OBSERVATION_SECONDS must be an integer")
if duration < 5 or duration > 120:
    raise SystemExit("OTEL_QUIESCE_OBSERVATION_SECONDS is outside 5..120")
expected_exporters = set(expected_exporters_text.splitlines())
expected_receiver_series = set(expected_receiver_series_text.splitlines())
if not expected_exporters or any(not value for value in expected_exporters):
    raise SystemExit("expected exporter set is empty or malformed")
if not expected_receiver_series or any("/" not in value or value.count("/") != 1 for value in expected_receiver_series):
    raise SystemExit("expected receiver series set is empty or malformed")

sample_re = re.compile(
    r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s+([-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?|NaN|\+Inf|-Inf)(?:\s+\S+)?$"
)
label_re = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')

def parse_labels(text):
    labels = {}
    if not text:
        return labels
    position = 0
    for match in label_re.finditer(text):
        if match.start() != position and text[position:match.start()].strip().strip(","):
            raise ValueError("invalid Prometheus labels")
        if match.group(1) in labels:
            raise ValueError("duplicate Prometheus label")
        labels[match.group(1)] = bytes(match.group(2), "utf-8").decode("unicode_escape")
        position = match.end()
    if text[position:].strip().strip(","):
        raise ValueError("invalid Prometheus labels")
    return labels

def fetch():
    request = urllib.request.Request(url, headers={"Accept": "text/plain; version=0.0.4"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status != 200:
                raise RuntimeError(f"metrics endpoint returned HTTP {response.status}")
            body = response.read(1024 * 1024 + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"live Collector metrics endpoint unavailable: {exc}") from exc
    if len(body) > 1024 * 1024:
        raise RuntimeError("live Collector metrics response exceeded 1048576 bytes")
    queues = []
    in_flight = []
    accepted = []
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"live Collector metrics are not UTF-8: {exc}") from exc
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        match = sample_re.fullmatch(line)
        if not match:
            raise RuntimeError("malformed Prometheus metric sample")
        name, raw_labels, raw_value = match.groups()
        try:
            labels = parse_labels(raw_labels)
            value = float(raw_value)
        except (ValueError, OverflowError) as exc:
            raise RuntimeError(f"invalid live Collector metric sample: {exc}") from exc
        if not math.isfinite(value):
            raise RuntimeError("live Collector metric is not finite")
        if name == "otelcol_exporter_queue_size":
            queues.append((labels, value))
        elif name == "otelcol_exporter_in_flight_requests":
            in_flight.append((labels, value))
        elif name == "otelcol_receiver_accepted_spans":
            accepted.append((labels, value))
    def exporter_values(series, label):
        values = {}
        for labels, value in series:
            exporter = labels.get("exporter")
            if exporter not in expected_exporters:
                raise RuntimeError(f"unexpected or missing {label} exporter label")
            if exporter in values:
                raise RuntimeError(f"duplicate {label} series for exporter {exporter}")
            values[exporter] = value
        if set(values) != expected_exporters:
            raise RuntimeError(f"{label} series do not exactly match expected exporters")
        return values
    queue_values = exporter_values(queues, "queue")
    in_flight_values = exporter_values(in_flight, "in-flight")
    receiver_values = {}
    for labels, value in accepted:
        receiver = labels.get("receiver")
        transport = labels.get("transport")
        series = f"{receiver}/{transport}"
        if receiver is None or transport is None or series not in expected_receiver_series:
            raise RuntimeError("unexpected or malformed receiver accepted-span series")
        if series in receiver_values:
            raise RuntimeError(f"duplicate accepted-span series for receiver {series}")
        receiver_values[series] = value
    if set(receiver_values) != expected_receiver_series:
        raise RuntimeError("accepted-span series do not exactly match expected receivers")
    if any(value < 0 for value in receiver_values.values()):
        raise RuntimeError("live Collector accepted-span counter is negative")
    if any(value != 0 for value in queue_values.values()):
        raise RuntimeError("live Collector exporter queue is not empty")
    if any(value != 0 for value in in_flight_values.values()):
        raise RuntimeError("live Collector exporter has in-flight requests")
    return {
        "queue_depth": int(sum(queue_values.values())),
        "in_flight_requests": int(sum(in_flight_values.values())),
        "accepted_spans": sum(receiver_values.values()),
        "queue_series": len(queue_values),
        "accepted_series": len(receiver_values),
    }

started = time.monotonic()
first = fetch()
last = first
while time.monotonic() - started < duration:
    time.sleep(min(1.0, max(0.0, duration - (time.monotonic() - started))))
    last = fetch()
    if last["accepted_spans"] != first["accepted_spans"]:
        raise SystemExit("live Collector accepted-span counter changed during quiescence observation")
    if last["queue_depth"] != 0 or last["in_flight_requests"] != 0:
        raise SystemExit("live Collector queue or in-flight request state changed during observation")
elapsed = time.monotonic() - started
if elapsed < duration:
    raise SystemExit("live Collector quiescence observation ended before its bounded interval")
if last["accepted_spans"] != first["accepted_spans"]:
    raise SystemExit("live Collector accepted-span counter was not stable")
print(json.dumps({
    "schema": "otel-live-quiescence-v1",
    "observed_seconds": round(elapsed, 3),
    "queue_depth": last["queue_depth"],
    "in_flight_requests": last["in_flight_requests"],
    "accepted_spans": last["accepted_spans"],
    "accepted_spans_stable": True,
    "queue_series": last["queue_series"],
    "accepted_series": last["accepted_series"],
}, sort_keys=True, separators=(",", ":")))
PY
}
