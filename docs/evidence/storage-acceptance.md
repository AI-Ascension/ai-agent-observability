# ClickHouse storage-isolation deployment acceptance

Status: unverified until a deployment/storage operator records every gate below.

This record is the operator-owned companion to issue #28. The repository
checklist may run in CI or another unprivileged checkout; the host/runtime fields
must be captured on the target host after the exact source and pinned images are
selected. Keep raw host paths, mount metadata, service logs, credentials, trace
payloads and backup contents private; attach only sanitized values and immutable
IDs.

## Repository snapshot

- Repository commit:
- Pull request:
- Compose project:
- Target host alias:
- Observation time (UTC):
- ClickHouse image ID/digest:
- Collector, Laminar and ClickHouse source image IDs:
- Storage manifest digest:

From the repository root, run the effect-free repository checklist against a
reviewed manifest:

```bash
bash ./deploy/storage/acceptance-report.sh \
  --manifest /absolute/path/to/reviewed/storage.tsv
```

Paste its deterministic `key=value` output here. The command checks only the
tab-delimited manifest syntax/schema; it does not require root, Podman, Docker,
ClickHouse, systemd, network access, credentials or application data. It never
starts or stops containers, mutates mounts, or inspects a host. A
`repository_checks=confirmed` line is repository evidence only. A valid report
exits `1` deliberately so that the unresolved external gates fail closed;
malformed arguments or input return a usage error. No report field declares
production acceptance.

The deployment/storage operator must append separate, sanitized evidence for
host inspection and runtime (image identity, mounts, logger, timer and bounded
log route), diagnostic forwarding, pressure lifecycle, migration/rollback,
sustained load and reboot persistence. Those checks require the approved
privileged host/deployment path and remain `unverified` until exercised.

## Gate record

| Gate | Evidence required | Status | Owner / next action |
| --- | --- | --- | --- |
| Immutable inputs and budgets | Image digest, measured retained/merge peaks, queue/store budgets, and approved physical allocations | unverified | Deployment/storage operator |
| Compose-to-Podman startup | Admitted manifest, account/profile settings, both bind mounts, and mount-loss/no-fallback behavior on the actual host | unverified | Deployment/storage operator |
| Diagnostic containment | Aggregate ClickHouse/conmon/journald/rsyslog ceiling under a full sink while unrelated host logs remain available | unverified | Deployment/storage operator |
| Pressure lifecycle | Installed timer, admission failure, stop ordering, failed-stop retries, durable latch, alerts, and restart refusal | unverified | Deployment/storage operator |
| Backup and migration | Quiesced consistent backup, migration/reconciliation, dual-backend ingestion, and rollback preserving post-cutover writes | unverified | Deployment/storage operator |
| Sustained operation | Upstream queue/store limits, 30–60 minute normal load, and coordinated reboot persistence | unverified | Deployment/storage operator |

The finite repository and disposable tests remain `source-derived` or
`confirmed` component evidence only. A `confirmed` field in the snapshot means
the corresponding read-only observation passed; it does not turn any row above
into live, migration, sustained-load, or reboot evidence. Issue #28 remains open
until the deployment/storage owner attaches sanitized evidence for every row.
