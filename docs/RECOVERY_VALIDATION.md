# Recovery integration review

Source under review: `a4700d6f8e11268c2cfbf3c4af8ef242301c7dd2`, followed by
the repair commit containing this record. No service or container was launched.

The root integration review found two faults in the persistent-queue test:
the delayed sink lacked the DNS alias configured by its source, and the
hand-encoded protobuf fixture had incorrect lengths/name bytes. The repair adds
the explicit `sink` network alias and a readable, jq-validated OTLP JSON fixture.
It also waits for the receiver listener and bounds curl connection/request time.

Backup documentation previously restarted every service with `compose up`,
used absolute checksum entries, and assumed Alpine's BusyBox tar supported GNU
ACL/xattr options. The corrected procedure records and restarts only previously
running exact containers, writes relocatable checksums, requires a staged
digest-pinned GNU tar image, and leaves restore stopped pending current operator
start authorization. These are reviewed procedures, not executed backup evidence.

Confirmed local checks:

- `bash -n tests/collector-persistence.sh`: passed.
- `bash tests/collector-invariants.sh`: static assertions passed; runtime skipped.
- `bash tests/collector-persistence.sh`: JSON/fixture checks passed; runtime skipped.
- `bash tests/validation-regressions.sh`: passed (fixtures only).
- `bash tests/bootstrap.sh`: passed (fixture bootstrap/environment preservation).
- `git diff --check`: passed.

Unavailable locally: Docker, Compose, and shellcheck. `compose-invariants.sh`
failed at its required Docker invocation; this is not a Compose validation pass.
CI requires both pinned-image validation and persistent-queue process replacement
tests (`COLLECTOR_RUNTIME_VALIDATE=required`,
`COLLECTOR_PERSISTENCE_RUNTIME=required`). Their results must be inspected at the
published exact head. Native container persistence, backend receipt, restore,
overflow/drop accounting, and live telemetry-plane evidence remain unverified.
