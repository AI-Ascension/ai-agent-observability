# Operations coding standards

This repository is prepared to adopt the operations profile of AI-Ascension/.github
standards. The canonical pinned profile and lock are coordinated with standards_lead;
this checkout currently has no local standards-profile.toml or standards.lock.json, so
the revision remains proposed until those files are distributed and validated. Merge
and protected-check activation remain separate owner actions. AGENTS.md and the
architecture, privacy and compatibility documents retain boundary authority.

Use Bash for the existing scripts, ShellCheck 0.10.0 for shell analysis, and the
Compose parser plus jq for structured deployment checks. ShellCheck's Linux
archive is pinned by SHA-256 in CI. The canonical structured gate checks Docker
Compose 2.39.4 and jq 1.8.1 before rendering. These are development checks, not
new image dependencies. Keep UTF-8/LF and existing EditorConfig indentation.
Use no formatter on frozen image pins, evidence or external data.

The read-only local gates are listed in CONTRIBUTING.md. Additional commands:

```bash
bash tests/compose-policy-regressions.sh
bash tests/compose-source-regressions.sh
bash tests/compose-structured.sh
```

The structured check renders only deploy/.env.example and never starts a
container. COMPOSE_BINARY may select an explicit standalone Compose executable.
The policy fixture test uses generated synthetic JSON, while the source regression
test renders disposable Compose copies and never starts a container. Both use the
checked-in contract and an isolated interpolation environment.
It requires nonempty service and port inventories, loopback host publishes,
protected persistent mounts, read-only configuration binds and disabled default
Laminar telemetry. Internal container binds are a different boundary and may
listen on all container interfaces. Existing bootstrap, ShellCheck, Dockerfile,
required-settings and text/privacy tripwires remain mandatory.

Compose parsing is static evidence only. Missing tools fail the command; Docker
build checks require their own available build tooling. No exception may suppress
privacy, unsafe listeners, lost persistence or a failed prerequisite. Approved
boundary changes require the existing owner issue/review process. This adoption
changes check tooling only, with no listener, runtime dependency or data mutation.
