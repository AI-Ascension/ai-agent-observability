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
  fresh backup verification, explicit approval/quiescence markers, single-service recreation, and rollback.

Validation is recorded in the handoff below and is source/build evidence only. No host mutation,
image build, service recreation, publication, or live health claim is made by this recovery lane.

## Current handoff hashes

Refresh these values after any further source edit:

```text
deploy/otel-health-probe.c  512f0925017385be01d9ae341b1ee8e58a6120ea80ffde591285d4eac0aba4f2
tests/otel-health-probe.sh  b9c8a02b587e4af8dd2c1937cff5d22223ffc04128dde97af7f5325edfd00c38
deploy/install-otel-health-probe.sh  6121567016966e29cbf6ef9721e5fcf4403ca36f6fd173af1576854908f5609c
docs/OTEL_HEALTH_PROBE.md  6a572465dc70ef7bc4d9fe4130f2173b111581b14d60fd8827cbc634a06933aa
deploy/compose.yaml  d0054cecb13316b30fc45acced195f097566e6fbfd94518baa0ed37dc6931c67
deploy/otel-collector.yaml  bfb0615bfab74b6ed39bbd3b073f90325a657145297cc9149af5d8fa48e94f80
deploy/Dockerfile.otel  354985e65f590a9602768b6469d526129effe3b85e4ea8cd9a4ebd718403b991
```

The durable recovery branch is `recovery/otel-corrected-health-probe-20260908`.
The installer requires the owner to pass the exact reviewed branch head (or a
coordinator-approved descendant) as `OTEL_EXPECTED_GIT_HEAD` before it can
mutate a host.

The exact missing historical commit remains unavailable; this lane is now **equivalent corrected
source available for owner review**, with live deployment still pending the coordinator's host,
image, mount, quiescence, and rollback gates.
