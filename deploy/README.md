# Deployment directory

This directory is self-contained after checkout. Run `./init.sh` once on a
host with Docker Compose or Podman. The script generates `.env` and starts the
full stack; `.env` is ignored by Git and must remain mode `0600`.

The bootstrap rejects malformed project/workspace UUIDs without changing them.
Earlier initializers could generate a five-character UUID variant group starting
with `10` or `11`. For a deployment affected by that defect, preserve the `.env`
and inspect its database identity before correcting only the affected ID: replace
that group's `10` prefix with `a`, or `11` with `b`. Do not regenerate the entire
environment, rotate secrets, or change an already valid database identity.
This repair requires an operator; rerunning initialization preserves the file.

## Runtime choices

- `COMPOSE_ENGINE=docker` uses Docker Compose. On a rootful Podman host, set
  `DOCKER_HOST=unix:///run/podman/podman.sock` and run the initializer with the
  required privilege.
- `COMPOSE_ENGINE=podman` uses the account's Podman Compose provider and
  rootless storage.
- `BIND_ADDRESS` defaults to `127.0.0.1`. Do not change it without reviewing
  authentication, firewall, TLS, and trace-data exposure.

The initializer creates the dedicated `ai-agent-observability-net` network. On
Podman-backed Docker sockets it sets `isolate=false`, which is required for
service-name DNS and container-to-container traffic on hosts that enable
network isolation by default.

## Agent endpoint

Prefer the collector for normal agent traces:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

The collector handles downstream authentication. If a direct Laminar SDK
connection is needed, use the local `.env` value for `LAMINAR_PROJECT_API_KEY`
through the operator's approved secret-reading method; never paste it into a
shell history, issue, log, or repository.

## Safe lifecycle commands

```bash
docker compose -p ai-agent-observability -f compose.yaml ps
docker compose -p ai-agent-observability -f compose.yaml logs --tail=100 otel-collector
docker compose -p ai-agent-observability -f compose.yaml up -d
```

Do not use `down -v` or prune commands. Use [`../docs/OPERATIONS.md`](../docs/OPERATIONS.md)
for backups, upgrades, systemd, and evidence capture.
