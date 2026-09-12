# `exact-checkpoint-reference-v1` contract (consumed copy)

Observability-consumed copy of the `sts2-protocol/exact-checkpoint-reference-v1` release-like
artifact (schema digest `028e00d06f9f2b16cb9097f47aedd057e74046a7cb2ba97362978e18029f48ab`).

The observability plane consumes only the closed, digest-free public reference envelope: a keyed
`ckpt-h1:` handle, an occurrence, boundary labels, and an assurance. Snapshots, exact-state digests,
blob digests, and privileged debug payloads stay out of telemetry. See
`tests/exact-checkpoint-reference.test.mjs` and run it with
`node --test tests/exact-checkpoint-reference.test.mjs`.
