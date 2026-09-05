# Contributing

Thank you for improving the AI-Ascension observability plane. This project
values explicit ownership, reproducible container inputs, least-privilege
defaults, and honest evidence over implementation speed.

## Before editing

Read:

- [`AGENTS.md`](AGENTS.md) for boundaries and evidence vocabulary.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for service ownership.
- [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) for pinned versions.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) for live-host procedures.
- [`docs/PRIVACY.md`](docs/PRIVACY.md) for data and egress handling.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for adapted files and
  image provenance.

Open an issue or reference an existing issue before changing a dependency,
public or private listener, authentication flow, retention policy, external
egress, schema bootstrap, or systemd lifecycle. Documentation-only corrections
may proceed directly when they preserve the accepted contract.

## Pull-request workflow

1. Create a focused branch from the current `main`.
2. Work in an isolated worktree and preserve unrelated local changes.
3. Assign file ownership before parallel work; no two agents edit one file.
4. Run the local static gates listed below.
5. If deployment is authorized, run the target-host gates without printing
   secrets and record the exact runtime evidence separately.
6. Push the branch and open a pull request. Do not merge, release, or broaden
   the deployment boundary without maintainer authorization.

## Static gates

```bash
for script in deploy/init.sh deploy/laminar/bootstrap-project-key.sh tests/*.sh tests/fixtures/*; do
  bash -n "$script"
done
shellcheck --severity=warning deploy/init.sh deploy/laminar/bootstrap-project-key.sh tests/*.sh tests/fixtures/*
git diff --check
bash tests/validation-regressions.sh
bash tests/compose-invariants.sh
bash tests/bootstrap.sh
```

With Docker Compose available:

```bash
docker compose --env-file deploy/.env.example -f deploy/compose.yaml config --quiet
bash tests/compose-required-settings.sh
docker buildx build --check -f deploy/Dockerfile.mlflow deploy
docker buildx build --check -f deploy/Dockerfile.laminar deploy
```

CI is authoritative for the complete repository gate. A passing static gate
does not prove that a host has started every service or accepted an OTLP span.

## Contribution license

By submitting a contribution, you represent that you have the right to provide
it and license it under the repository's [MIT License](LICENSE). Identify
adapted or generated material and retain applicable upstream notices. Do not
submit credentials, private traces, prompts, model output, datasets, weights,
or source whose distribution terms are unknown.
