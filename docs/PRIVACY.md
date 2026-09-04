# Privacy and data handling

## Default posture

The deployment binds to loopback and stores tracking data locally in persistent
volumes. No public Caddy route is installed by this repository. This is a
security boundary, not a guarantee that trace payloads are safe: any process
with access to the host or tunnel can potentially inspect the configured UIs.

## What is stored

- MLflow stores experiment metadata, parameters, metrics, tags, and artifacts.
- RustFS stores MLflow artifacts, which may contain models, reports, or files
  uploaded by a researcher.
- Laminar stores spans, inputs/outputs included in spans, project metadata,
  evaluation records, and search indexes.
- PostgreSQL, ClickHouse, RabbitMQ, and Quickwit retain the supporting records
  required by the two products.

Retention is controlled by the product stores and operator backup policy. This
repository does not promise automatic deletion of research data.

## Redaction and minimization

The Collector does not inspect or redact arbitrary span attributes. Agents and
harness adapters must:

1. avoid passwords, API keys, cookies, access tokens, private prompts, and
   personal data;
2. minimize model input/output to the fields needed for the research question;
3. apply a tested redaction processor or adapter before export when sensitive
   values are unavoidable; and
4. document the data classification and retention period for each experiment.

The generated Laminar collector key is ingest-only. The database stores only
its hash; the plaintext is kept in the target `.env` so the Collector can send
the bearer header.

## External egress

Normal runtime traffic is local container-to-container traffic. Egress occurs
for image pulls and package/image builds. Optional Laminar AI features can send
selected data to a configured model provider; they are disabled by default in
this repository (`LLM_API_KEY` and `OPENAI_API_KEY` are empty). Laminar's
anonymous self-hosted usage telemetry is explicitly disabled by default with
`LAMINAR_TELEMETRY_DISABLED=true`.

Review any future reverse proxy, OAuth provider, model provider, Slack, email,
or cloud-storage configuration as a separate privacy and security change.
