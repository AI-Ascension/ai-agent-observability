# Operations package refresh review

Review date: 2026-09-07. This review covers the bounded adoption refresh for
`AI-Ascension/ai-agent-observability` in the isolated
`codex/standards-current-20260907` worktree. It records source, static and
synthetic-process evidence separately from deployment evidence.

## Exact source heads

The requested upstream base was `28a48590afb75b07590e1b78ea47dae08f5c3ade`.
The observed `origin/main` ref resolved to that same commit. The supplied old
baseline was `b25880376d3a3334c77f58637267db93581c4c77`; its first-parent task
range contained these eight commits, applied in order:

| Commit | Change |
| --- | --- |
| `0de77910fffb69a53c57c47e3e379f15c0bd63fa` | parsed deployment invariants in local and CI gates |
| `3e7fcdb6ad426cb0d4ae3006b9c3b7209c291a8d` | bounded Compose topology checks |
| `4031bc674341353fc52fe239c9d53affa8954639` | closed Compose lifecycle and option bypasses |
| `850419c3d88e3bde1e99d8fc04c25953f4c2d2a3` | adopted pinned local standards and native CI checks |
| `b7f0f250bccaeeb0e9713ca4c93258579d17ad59` | pinned refreshed standards and mandatory production lint |
| `59f1ffe3e339d1621bd73697e2ec75ed9f76742b` | refreshed the standards pin after guidance comparison |
| `46d13d2a1ffbb8a7ba7d61b649f14db0aa003b3a` | clarified owner-specific Rust check guidance |
| `9dedb4807bd5c48ff5f49e590e07de97e42e177f` | added the supplied rule catalog and style-only exception enforcement |

Before this review's local additions, the resulting current branch head was
`9dedb4807bd5c48ff5f49e590e07de97e42e177f`. The current branch commit that
contains this review records the final Git head in the handoff; the source
heads above are the immutable integration inputs.

## Changes and counts

The eight commits above contribute 49 changed paths relative to the requested
upstream base, with 7,259 insertions and 5 deletions. The bounded refresh then
touches eight implementation paths before this review:

- `.github/workflows/ci.yml` adds the query-provision regression to the
  existing no-container validation step while retaining the `validate` job,
  `Validate deployment contract` job name, `merge_group` trigger, pinned
  ShellCheck, Compose and jq setup, and the existing required checks.
- `tests/compose-contract.json` adds the two upstream `laminar-frontend`
  read-only ClickHouse environment keys exactly; it does not broaden the
  approved service or topology contract.
- `tests/query-provision-regressions.sh` and its 13-line
  `tests/fixtures/query-provision-podman` exercise stopped and erroring
  synthetic Podman preflights. They compare hashes of an existing dotenv file,
  query-key marker and private state, and reject any operation beyond
  `podman inspect`. Root execution returns 69 for a stopped/erroring service;
  non-root execution returns the helper's status 64 root guard.
- `standards-profile.toml`, `standards.lock.json`,
  `standards/repositories.yaml`, and
  `standards/tools/standards-sync/src/conformance_tests.rs` refresh the local
  generated bundle metadata and conformance coverage. The source bundle is
  pinned to `AI-Ascension/.github` commit
  `2be70b28a8359caea1c7ce9996a268ce4b278fc4` with digest
  `sha256:5633c46a179b9fd67e6116253e76ee11c142b73ae90a38cb63f0498ac9ecf77f`.
  The conformance test rejects a valid 40-hex tree or blob object when it is
  supplied as a source commit. No copied `standards/` rule text was edited.

The implementation delta is 114 added and 16 removed lines across those eight
paths. The review file is an additional documentation path. The current
standards directory contains 36 files and 5,910 physical lines; those counts
include the supplied schemas, fixtures, tool source and lockfile.

## Validation evidence

The following are read-only checks run against this worktree:

| Command or scope | Result |
| --- | --- |
| `bash -n` on deploy scripts, tests and fixtures | passed |
| ShellCheck 0.10.0 at warning severity on the same scope | passed |
| `bash tests/bootstrap.sh` | passed |
| `bash tests/validation-regressions.sh` | passed |
| `bash tests/query-provision-invariants.sh` | passed |
| `fakeroot bash tests/query-provision-regressions.sh` | passed stopped/error synthetic preflights; no mutation |
| `bash tests/compose-policy-regressions.sh` | passed, 1 positive and 43 negative cases |
| `bash tests/compose-source-regressions.sh` | passed, 1 positive and 18 negative cases |
| `bash tests/compose-structured.sh` | passed with Compose 2.39.4 and jq 1.8.1 |
| `bash tests/compose-invariants.sh` | passed with the pinned standalone Compose renderer |
| `bash tests/compose-required-settings.sh` | passed, all 24 missing/blank cases |
| `cargo +1.97.1 run --locked --manifest-path standards/tools/standards-sync/Cargo.toml -- validate --root .` | passed |
| `git diff --check` | passed |

The Compose checks rendered only the checked-in example environment and
disposable synthetic models. They did not contact a Docker daemon. The query
regression uses a fake executable and temporary state; it did not run a real
Podman command, initialize a service, mutate a database, create an account or
write credentials.

## Limits and rollback

Docker/buildx is unavailable in this environment, so the two existing
Dockerfile build-check lanes remain unverified. No hosted CI run, remote branch,
pull request, issue, settings, protection rule, deployment, container, service,
mail delivery, image build, volume, database or live ingestion test was run.
Static Compose parsing does not establish service health, query access,
persistence, restart behavior or end-to-end trace delivery. The new synthetic
test establishes the stopped/error preflight boundary only.

The current worktree is a branch from the requested upstream base and keeps the
existing required check names. Rollback is a normal Git revert of the commit
containing this review and the bounded changes; no deployment or persistent
volume rollback is required.
