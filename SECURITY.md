# Security Policy

## Reporting a vulnerability

Use the repository's private vulnerability reporting channel when available.
If it is unavailable, open a minimal public issue requesting a private contact
path; do not include exploit details, credentials, private traces, prompts,
model output, personal paths, or host access information.

Include the affected commit or image tag, boundary, impact, reproducible
conditions, and the smallest safe proof. Maintainers should coordinate a fix
and disclosure window privately.

## Deployment security boundary

The default deployment is loopback-only and is intended to be reached through
an SSH tunnel or an approved private network. Before changing `BIND_ADDRESS`,
review authentication, TLS, firewall policy, Caddy ownership, and the data
classification of traces and artifacts.

The `.env` file is the deployment secret store for this Compose project. It
must be mode `0600`, must stay on the target host, and must not be pasted into
issues, logs, CI output, or pull requests. Rotate generated secrets after an
exposure or host-access change.
