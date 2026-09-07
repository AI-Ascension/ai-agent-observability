# Standards check evidence

Source baseline: b25880376d3a3334c77f58637267db93581c4c77, default branch main,
repository ID 1357224960. Evidence date: 2026-09-07. The prepared branch changes
local validation and CI source only; it does not alter deployment configuration. The
local standards profile and lock are pending distribution coordinated with
standards_lead; this document makes no local standards-lock validation claim.

## Observed local results

| Command | Result |
| --- | --- |
| bash -n on deploy scripts, tests and command fixtures | Passed |
| shellcheck --severity=warning on the same scope | Passed with ShellCheck 0.10.0 |
| bash tests/bootstrap.sh | Passed UUID variants, private dotenv preservation, non-execution and invalid identity checks |
| bash tests/validation-regressions.sh | Passed unsafe-binding and identity-leak mutation rejection |
| bash tests/compose-policy-regressions.sh | Passed 1 positive and 43 negative structured-model fixtures |
| bash tests/compose-source-regressions.sh | Passed 1 positive and 18 negative rendered-source fixtures |
| bash tests/compose-structured.sh | Passed on the actual example Compose model |
| bash tests/compose-invariants.sh | Passed using the actual standalone Compose renderer |
| bash tests/compose-required-settings.sh | Passed all 24 missing/blank setting cases |
| git diff --check | Passed |

The renderer was Docker Compose 2.39.4, release SHA-256
7af95166a730b87e172d4fc9aefea8725d3c6c7327d59149267b452114ddb7d4,
invoked through an isolated command adapter for existing docker-compose callers.
No Docker daemon or container was started. The parser was jq 1.8.1, whose Linux
archive is pinned in CI to release SHA-256
020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d. CI also
provisions the same Compose binary and jq archive into the runner's temporary
directory after verification; it does not install either tool system-wide. CI
pins the
ShellCheck 0.10.0 Linux archive to
6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87.
The existing checkout action SHA was verified against its upstream commit API.

The new filter checks an exact approved service, image/build, environment-key,
dependency, lifecycle, network, port and volume topology. It rejects arbitrary
services, host credential paths, driver bind options, host namespaces, devices,
unreviewed capabilities, unapproved lifecycle values and unconfined security
options. It preserves and compares Compose's executable entrypoint, healthcheck,
restart, pull policy, container name and ulimit fields; normalized port and mount
objects retain their observed option boundaries. It requires loopback host
publishes, the six named data volumes, three read-only configuration binds, the
external network, and Laminar/provider telemetry opt-outs. Negative fixtures remove
or weaken each covered property. Existing text tripwires remain supplemental;
neither them nor the structured filter is a complete deployment security analysis.

The bootstrap fixture passes literal command substitution text as existing dotenv
data and confirms the initializer neither executes it nor alters the file. All
initializer tests use synthetic command executables and isolated temporary data.

## Unverified and unchanged boundaries

Dockerfile build-check execution is unavailable locally because Docker/buildx is
not installed; its existing CI steps remain mandatory. Hosted CI was not run by
this local-only task. No image, runtime dependency, listener, authentication flow,
retention, egress, data volume or service lifecycle was changed. Container health,
ingestion, persistence across restart and deployment remain separate unverified
runtime claims. No issue, PR, remote branch, settings, mail or deployment write
was performed.

Rollback this validation commit with a normal Git revert on a review branch;
there is no deployment or volume rollback. Retain the original ShellCheck,
bootstrap, required-settings and Dockerfile checks when revising the new gate.
