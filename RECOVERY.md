# OTel source recovery status

Repository: `AI-Ascension/ai-agent-observability`. Recovered source path:
`recovered/otel-source-a126715/`.

The checkout began at the published branch commit
`a126715501d65a2d25f9d6ecf9c6bd142cc5f590`. The reviewed target commits
`1043354` and `1ccf10252f9fc1a69f10dbbab4dc2fc7c2a08e55` were not available
from the remote after the temporary workspace was lost. Their review findings
were reimplemented in the durable source rather than treating the stale
checkout as deployable.

The corrected source now includes:

- strict bounded ASCII JSON parsing with duplicate-key and trailing-data rejection;
- active `service.pipelines.traces.exporters` parsing with unknown-exporter fail-closed behavior;
- one monotonic two-second deadline shared across the Collector, DNS, and downstream checks;
- a static IPv4 resolver with responder, transaction, question, canonical owner, A/CNAME-chain,
  duplicate, and loop validation;
- dependency fixtures covering direct A, CNAME, unrelated, duplicate, question-mismatch, and loop answers;
- `deploy/install-otel-health-probe.sh`, a source/config/image/mount/digest guarded installer with
  fresh backup verification, explicit approval/quiescence proof, single-service recreation, expanded
  runtime identity verification, independent rollback budget, and rollback compensation.
- `tests/otel-installer-guards.sh`, fake-engine fixtures for read-only preflight, env-file forwarding,
  bounded engine output, image-build failure, and verified rollback.

Validation is recorded in the handoff below and is source/build evidence only. No host mutation,
image build, service recreation, publication, or live health claim is made by this recovery lane.

## Current handoff hashes

Refresh these values after any further source edit:

```text
deploy/otel-health-probe.c  4177d4ec6f7765f7edc63ca9f56bc65a53e50a025ad37a6baf8b9a8ddf847db2
tests/otel-health-probe.sh  021d6dd931b37272f3b6493abb951277d5b7bb5f80cd52c983a5e1c1e9d75ea5
tests/otel-installer-guards.sh  b9ac09a907e2eb6f6dd93c4fac8fa0b19fbf5f152beb2ddccc4150231beb4a82
deploy/install-otel-health-probe.sh  650776525fb2258a2dea820b05d36a53c314430908acd76e98c601fd51acd56f
docs/OTEL_HEALTH_PROBE.md  c24b0c2b799f8c4d31f96f59063eb83c4e581650aafd8629ae48a074158c2441
deploy/compose.yaml  1ee4f211dae9d919a6536789117f38182703c70fa0f97debd55332ecabc9424d
deploy/otel-collector.yaml  e568580c2d26e4b835917cd08a1a23913c6b27facebfb3b1e5941ef2cef72f93
deploy/Dockerfile.otel  354985e65f590a9602768b6469d526129effe3b85e4ea8cd9a4ebd718403b991
```

The durable recovery branch is `recovery/otel-corrected-health-probe-20260908`.
The installer requires the owner to pass the exact reviewed branch head (or a
coordinator-approved descendant) as `OTEL_EXPECTED_GIT_HEAD` before it can
mutate a host.

The exact missing historical commit remains unavailable; this lane is now **equivalent corrected
source available for owner review**, with live deployment still pending the coordinator's host,
image, mount, quiescence, and rollback gates.
