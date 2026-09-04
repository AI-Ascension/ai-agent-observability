# Operations

## First deployment on a Podman host

Copy the repository to a dedicated directory on the target host, then run the
initializer as the account that owns the deployment directory. For the
rootful/system Podman convention used by the Train domain, the command is:

```bash
cd /home/completetrain/ai-agent-observability/deploy
sudo env DOCKER_HOST=unix:///run/podman/podman.sock COMPOSE_ENGINE=docker ./init.sh
```

The initializer creates `.env` with mode `0600`, validates the Compose model,
builds the two wrapper images, and starts only the services in this project.
It never overwrites an existing `.env`. Keep the generated file on the target
host; do not copy it into Git, CI, or chat.

If a normal Docker daemon is intentionally used, omit `sudo` and
`DOCKER_HOST`. If rootless Podman is intentionally used, run with
`COMPOSE_ENGINE=podman` and use the account's own Podman storage.

## Install boot orchestration

After the first successful start, install the checked-in systemd unit:

```bash
sudo install -m 0644 ../systemd/ai-agent-observability.service \
  /etc/systemd/system/ai-agent-observability.service
sudo systemctl daemon-reload
sudo systemctl enable --now ai-agent-observability.service
```

The unit uses the rootful Podman API socket, an explicit project name, and
`--no-build` on boot. Builds and upgrades remain deliberate operator actions.

## Inspection without secret output

```bash
cd /home/completetrain/ai-agent-observability/deploy
sudo env DOCKER_HOST=unix:///run/podman/podman.sock \
  docker compose -p ai-agent-observability -f compose.yaml ps
sudo podman ps --filter name=ai-agent-observability --format '{{.Names}}|{{.Status}}|{{.Ports}}'
sudo systemctl status ai-agent-observability.service --no-pager
```

Health probes are intentionally bounded to loopback:

```bash
curl -fsS http://127.0.0.1:15000/health
curl -fsS http://127.0.0.1:18000/health
curl -fsS http://127.0.0.1:15667/ >/dev/null
```

The Collector has no HTTP health endpoint in this minimal configuration; its
container state and logs should be checked together with the downstream smoke
test. Do not treat a running Collector process as proof of accepted traces.

## Browser access

Use an SSH tunnel from a trusted workstation rather than changing the default
bind address:

```bash
ssh -N \
  -L 15667:127.0.0.1:15667 \
  -L 15000:127.0.0.1:15000 \
  -L 14318:127.0.0.1:14318 \
  target-host
```

Then open `http://127.0.0.1:15667` or `http://127.0.0.1:15000` locally. The
first Laminar login uses the passwordless local-email flow. The email set by
`LAMINAR_ADMIN_EMAIL` receives the pending workspace invitation; configure it
before first initialization if a different operator identity is required.

## Backups and upgrades

Back up the six named volumes with a host-approved, quiesced procedure before
upgrading. At minimum, preserve Laminar PostgreSQL, ClickHouse, Quickwit, and
MLflow PostgreSQL/RustFS data. Record the image tags and Compose commit with
each backup. Never use `down -v` as a backup or rollback mechanism.

For an upgrade, change one pinned version, run the static CI gates, pull/build
only the affected image, and use `docker compose up -d` for this project. Check
health, logs, an OTLP smoke span, and persistence after restart. Roll back by
restoring the prior checked-in tags and the approved data snapshot; do not
delete live volumes to force a migration.

## Failure boundaries

- Image pull/build failure: build evidence is unavailable; existing running
  services are not changed by the failed build.
- Database or search failure: health and end-to-end evidence are unavailable;
  inspect only this project's named containers and volumes.
- Collector export failure: inspect downstream health and Collector logs; the
  queue is bounded and retries are finite.
- Authentication failure: rotate the project key in the deployment `.env` by
  an approved procedure and recreate only this project's bootstrap/Collector
  path. Never place the key in a command-line transcript.
