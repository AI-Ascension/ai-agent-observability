#!/usr/bin/env bash
set -euo pipefail

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${LAMINAR_PROJECT_API_KEY:?LAMINAR_PROJECT_API_KEY is required}"
: "${LAMINAR_PROJECT_ID:?LAMINAR_PROJECT_ID is required}"
: "${LAMINAR_WORKSPACE_ID:?LAMINAR_WORKSPACE_ID is required}"
: "${LAMINAR_PROJECT_NAME:?LAMINAR_PROJECT_NAME is required}"
: "${LAMINAR_WORKSPACE_NAME:?LAMINAR_WORKSPACE_NAME is required}"
: "${LAMINAR_ADMIN_EMAIL:?LAMINAR_ADMIN_EMAIL is required}"

if [[ ${#LAMINAR_PROJECT_API_KEY} -ne 64 ]]; then
  printf '%s\n' 'LAMINAR_PROJECT_API_KEY must be exactly 64 characters' >&2
  exit 64
fi

# Reject persisted malformed identities before waiting for or changing the DB.
# Never regenerate them here: existing identities belong to the deployment.
uuid_pattern='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
for identity_name in LAMINAR_PROJECT_ID LAMINAR_WORKSPACE_ID; do
  if [[ ! ${!identity_name} =~ $uuid_pattern ]]; then
    printf '%s must be a canonical UUID; correct that identity in deploy/.env without replacing other values.\n' "$identity_name" >&2
    exit 64
  fi
done

database_args=(
  --host=laminar-postgres
  --port=5432
  --username="$POSTGRES_USER"
  --dbname="$POSTGRES_DB"
  --no-password
)

readiness_args=(
  --host=laminar-postgres
  --port=5432
  --username="$POSTGRES_USER"
  --dbname="$POSTGRES_DB"
)

until PGPASSWORD="$POSTGRES_PASSWORD" pg_isready "${readiness_args[@]}" >/dev/null 2>&1; do
  sleep 2
done

until schema_ready="$({
  PGPASSWORD="$POSTGRES_PASSWORD" psql "${database_args[@]}" -Atqc \
    "SELECT (to_regclass('public.project_api_keys') IS NOT NULL) AND (to_regclass('public.workspace_invitations') IS NOT NULL) AND (to_regclass('public.subscription_tiers') IS NOT NULL) AND EXISTS (SELECT 1 FROM subscription_tiers WHERE id = 1);"
} 2>/dev/null)" && [[ "$schema_ready" == t ]]; do
  sleep 2
done

api_key_hash="$(printf '%s' "$LAMINAR_PROJECT_API_KEY" | openssl dgst -sha3-256 -r | awk '{print $1}')"
api_key_shorthand="$(printf '%s...%s' \
  "$(printf '%s' "$LAMINAR_PROJECT_API_KEY" | cut -c1-4)" \
  "$(printf '%s' "$LAMINAR_PROJECT_API_KEY" | tail -c 4)")"

PGPASSWORD="$POSTGRES_PASSWORD" psql "${database_args[@]}" \
  --set=workspace_id="$LAMINAR_WORKSPACE_ID" \
  --set=workspace_name="$LAMINAR_WORKSPACE_NAME" \
  --set=project_id="$LAMINAR_PROJECT_ID" \
  --set=project_name="$LAMINAR_PROJECT_NAME" \
  --set=admin_email="$LAMINAR_ADMIN_EMAIL" \
  --set=api_key_hash="$api_key_hash" \
  --set=api_key_shorthand="$api_key_shorthand" \
  --single-transaction -f - -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO workspaces (id, name, tier_id, settings)
VALUES (:'workspace_id'::uuid, :'workspace_name', 1, '{}'::jsonb)
ON CONFLICT (id) DO NOTHING;

INSERT INTO projects (id, name, workspace_id, settings)
VALUES (:'project_id'::uuid, :'project_name', :'workspace_id'::uuid, '{}'::jsonb)
ON CONFLICT (id) DO NOTHING;

DELETE FROM project_api_keys
WHERE project_id = :'project_id'::uuid
  AND name = 'ai-agent-observability collector';

INSERT INTO project_api_keys
  (name, project_id, shorthand, hash, is_ingest_only, user_id, expires_at, value)
VALUES
  ('ai-agent-observability collector', :'project_id'::uuid, :'api_key_shorthand',
   :'api_key_hash', true, NULL, NULL, '');

INSERT INTO workspace_invitations (workspace_id, email)
SELECT :'workspace_id'::uuid, :'admin_email'
WHERE NOT EXISTS (
  SELECT 1
  FROM members_of_workspaces
  WHERE workspace_id = :'workspace_id'::uuid
    AND user_id IN (SELECT id FROM users WHERE email = :'admin_email')
)
AND NOT EXISTS (
  SELECT 1
  FROM workspace_invitations
  WHERE workspace_id = :'workspace_id'::uuid
    AND email = :'admin_email'
);
SQL

printf '%s\n' 'Laminar ingest project and pending operator invitation are ready.'
