# ClickHouse storage candidate evidence

Issue #28. Source and disposable runtime evidence; no production rollout or acceptance.

## Exact-release disposable runtime

Confirmed in GitHub Actions run 34702985965, job 103577913449, at commit 183238f:
Podman 4.9.3 tested ClickHouse 26.5.7.64, immutable image ID
`06ff3b41deae711cc50269b31cf438fca8dcbd1fd180145d538bf9389eae9ea9`.
Native file sinks were absent and console logging enabled. The finite log flood
retained 57,766 aggregate bytes, counting rotation files, with a configured 512KB
limit and a 2MiB maximum test bound.

The isolated server test passed read-only startup with bounded temporary mounts,
authenticated account and profile checks, rejection of a large insert due to full
data storage, existing-row reads with full diagnostic storage, and preservation of
two committed rows through container replacement. Test storage used fully allocated
1GiB/64MiB loop-backed ext4 filesystems on a disposable runner.

This establishes CLI container behavior for that exact image, not production device
admission, the Compose API integration, a continuous error flood into a full log sink,
bounded alternate host logging, real ingestion, pressure-monitor/alert delivery,
production migration or Windows recovery. The production image digest remains unknown.

## Earlier compatibility evidence and remaining gates

Confirmed on the inspected Podman 4.9.3 host:

- Compose renders the base plus storage-isolation override with required data and
  diagnostic paths supplied. This is static configuration evidence only.
- A disposable rootless run using pre-existing image ID
  `63a3278e83e17a06021840748a1f6b3c905828d76783c1174677686bf64a7f1e`
  found both native logger file keys absent and console enabled.
- The finite approximately 8MiB diagnostic flood including a 1MiB line left 80,570
  bytes in the `k8s-file` capture with configured `max-size=512kb`. Test container
  and scratch logs were removed after success. This proves neither a filesystem
  quota nor steady-state byte plateau under an indefinitely failing service.
- Subsequent native version identification found **25.12.3.21**, not the production
  incident's 26.5.7.64. Treat that run as preliminary compatibility evidence only.
  The runtime test now requires version 26.5.7.64 and returns 77 for a different image.

Source-derived: the 26.5.7.64 entrypoint uses optional native extraction for logger
file paths and only creates their directories when those paths are present. It also
generates account XML in users.d, which explains the override's bounded writable
tmpfs there. Neither fact proves complete server startup with this overlay.

Production rootful inventory/mutations remain inaccessible through current normal
administrator access. The installed allowlisted service helper exposes status but
does not expose ClickHouse inspect/exec or storage provisioning. No bypass was used.
Health reports do not contradict the observed diagnostic error storm.

Local candidate checks: 18 command-fixture admission cases pass, including missing/
replaced/readonly mounts, device aliases, unsupported thin/loop ancestry, exhausted
bytes/inodes, invalid counters, duplicate keys and unsafe manifest permissions.
ShellCheck 0.9.0 passes for the new scripts and modified initializer. Existing
bootstrap and validation-regression fixtures pass. The rendered Compose test checks
that omitted mount paths fail, data mounts replace the named-volume target, logging
is bounded and the root filesystem is read-only. These are static/fixture results;
they are not proof that an actual physical allocation or pressure-stop works.

Review follow-up: local lifecycle tests now use real process locks to prove mutual
exclusion and inject persistent-marker failure while checking that all three stop
attempts still occur. Missing, symlink-substituted and nested bind directories are
rejected in fixture tests. Startup shares the monitor lock, requires prebuilt images,
prohibits automatic pulls, and limits its external command durations. Runtime and
persistent markers are checked; failed persistent writes still require operator
reconciliation before reboot. This is not yet live shutdown/reboot evidence.

GitHub Actions run 34701880578 at candidate 35de751 passed deployment-contract and
recorded-run-consumer checks. Both disposable ingestion jobs failed at Collector
health, before trace injection. The archived stack metadata reports ClickHouse and
Laminar healthy and Collector unhealthy; Collector output has no diagnostic errors.
This does not establish why its health probe failed. The smoke test now captures
the Collector's health-check metadata and loopback component status for diagnosis.
Base-main run 34699763967 at 3390924 also failed both ingestion modes at Collector
health. The symptom predates this branch; it remains an acceptance blocker.

Run 34702403289's missing-ingestion diagnostic archive reports HTTP 200,
`healthy: true`, `StatusOK` from the Collector's loopback component endpoint while
the installed probe exits 1. A regression test using the checked-in two-exporter
configuration reproduces a parser defect: `exporter_endpoint` reset its selected
endpoint state when reading the next sibling exporter. The fix preserves the chosen
endpoint and rejects repeated definitions. Runtime ingestion must still pass before
claiming this resolves the full CI failure.

Run 34702985965 confirms Collector health now passes and the missing-ingestion
negative case succeeds. The positive case accepts the OTLP request, then MLflow
rejects its search requests with HTTP 403: the log names an invalid Host header
containing the ephemeral published port. The test now uses the already admitted
`localhost:5000` authority while connecting to its private ephemeral loopback port;
production Host validation is unchanged. It also uses current span timestamps and
real newlines between multiple trace IDs. Positive end-to-end acceptance remains
pending the next run.

Unverified: exact root cause of the log file-access failure, production image digest,
actual production data sizing, production hard allocation provisioning and account
grants, production startup/migration, pressure/stop/reboot controls, bounded host log
routing, end-to-end ingestion, rollback, sustained observation and Windows recovery.
