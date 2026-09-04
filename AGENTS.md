# Repository Instructions for Coding Agents

## Scope and authority

This repository owns declarative deployment, operational documentation, and
validation for the AI-Ascension AI-agent observability plane. It does not own
the STS2 harness, game behavior, provider implementations, model weights,
private datasets, or proprietary game files.

Follow direct user instructions first, then this file, then the documents
linked from [`CONTRIBUTING.md`](CONTRIBUTING.md). Every change must have one
cohesive responsibility, an explicit file owner, and an evidence plan.

## Non-negotiable boundaries

- Use a new branch and worktree for implementation; never commit directly to
  `main`.
- Open or reference an issue before changing dependencies, listeners,
  authentication, routes, retention, or external egress.
- Never commit passwords, API keys, bearer tokens, private keys, `.env` files,
  personal filesystem paths, private traces, prompts, model output, or model
  weights.
- Never alter the existing STS2 repositories, shared Caddy configuration, or
  another Compose project as part of this repository's deployment.
- Do not use `compose down -v`, volume deletion, broad cleanup, or image-store
  pruning as a troubleshooting shortcut.
- Keep default host listeners loopback-only. A non-loopback bind requires an
  explicit security review and a documented private-network boundary.
- Keep implementation logic in the declared container/service boundary. This
  repository contains no Python application source and must not become a second
  harness implementation.

## Evidence vocabulary

Use these states precisely:

- `confirmed` — directly observed at the exact commit, host, or endpoint named.
- `source-derived` — supported by upstream source or official documentation.
- `proposed` — intended design or configuration not yet exercised.
- `inferred` — reasoned from observed facts but not directly tested.
- `unverified` — not tested or not available in the current environment.
- `unsupported` — outside the declared compatibility boundary.

A Compose parse is static evidence. An image build is build evidence. A
container healthcheck is runtime evidence. A trace visible in both products is
end-to-end evidence. Do not collapse those claims.

## Required workflow

1. Read `README.md`, `CONTRIBUTING.md`, the applicable architecture/operations
   documents, and the live domain context before remote changes.
2. Inspect the current checkout and target host without resetting, cleaning,
   broadly staging, or overwriting unrelated work.
3. Assign every touched file to one specialist and use explicit handoffs.
4. Validate Compose, Dockerfiles, YAML, shell, secret hygiene, and the
   relevant runtime boundary.
5. Report exact commit, branch, remote head, CI checks, service names, ports,
   health endpoints, and remaining unverified claims.

Use `apply_patch` for repository file edits. Maintain separate source, build,
runtime, live, and end-to-end evidence records.
