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
tests/otel-installer-guards.sh  7ea9dbc2c50884f9504b55b295e1aebda66e432a528c28f6fd22367f78067991
deploy/install-otel-health-probe.sh  461f0e4c3e10f58966d13ac547368cfae4ef624a6cfa6008f249e3647c6103ba
docs/OTEL_HEALTH_PROBE.md  1cf062a0eb62d810526d4c1d628141f438cd96e2a14f714532181f302da14f83
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
