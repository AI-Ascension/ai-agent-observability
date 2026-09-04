# Evidence record

Use this template for deployment notes. Keep secrets, trace payloads, prompts,
model output, personal paths, and private host identifiers out of the record.

## Identity

- Repository commit:
- Branch / PR:
- Target host alias:
- Deployment directory:
- Compose project:
- Observation time (with timezone):

## Source and build

- Compose parse: `confirmed` / `unverified`
- Dockerfile checks: `confirmed` / `unverified`
- Image build tags and digests:
- CI run and exact commit:

## Runtime

- Systemd unit state:
- Container names and health states:
- MLflow `/health`:
- Laminar `/health`:
- Laminar frontend:
- Collector process/state:
- Host listener scope:

## End-to-end

- Test trace identity (non-sensitive synthetic ID):
- OTLP input protocol:
- MLflow receipt/query:
- Laminar receipt/query:
- Persistence after controlled service restart:
- Public/private route status:

## Exceptions

List each remaining `proposed`, `inferred`, `unverified`, or `unsupported` claim
and the exact next check needed. A green CI run does not replace a live or
end-to-end check.
