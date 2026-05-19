#!/usr/bin/env bash
# Entrypoint for openclaw-render-template-gbrain.
#
# Runs on every container start, but the expensive steps (CREATE EXTENSION,
# gbrain init schema, skills seed) are idempotent and short-circuit on reboots.
# Failures here exit non-zero so Render surfaces the problem instead of
# starting AlphaClaw against a half-initialized brain.

set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Validate required environment.
# ---------------------------------------------------------------------------
require_env() {
  if [ -z "${!1:-}" ]; then
    log "ERROR: $1 is not set. See README.md for required env vars."
    exit 1
  fi
}

require_env DATABASE_URL
require_env OPENAI_API_KEY
require_env ANTHROPIC_API_KEY
require_env ALPHACLAW_ROOT_DIR

mkdir -p "$ALPHACLAW_ROOT_DIR"
mkdir -p "$ALPHACLAW_ROOT_DIR/skills"
mkdir -p "${GBRAIN_HOME:-/data/.gbrain}"

# ---------------------------------------------------------------------------
# 2. Enable Postgres extensions GBrain depends on.
#    Render Postgres permits CREATE EXTENSION for vector and pg_trgm without
#    superuser. Wrap in a single transaction so the check is one round trip.
# ---------------------------------------------------------------------------
log "Ensuring pgvector + pg_trgm extensions are enabled..."
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL

# ---------------------------------------------------------------------------
# 3. Initialize the GBrain schema (idempotent: safe to re-run).
#    The init wizard normally prompts for a connection URL; passing --url
#    skips the wizard and writes config to $GBRAIN_HOME/config.json.
#
#    Known issue on Render Managed Postgres: GBrain migration v24
#    (rls_backfill_missing_tables) requires the connecting role to hold the
#    BYPASSRLS attribute. Render never grants BYPASSRLS to user roles
#    (only the platform's superuser has it), so v24 throws and aborts the
#    whole init. See https://github.com/garrytan/gbrain/issues/416 for the
#    upstream design discussion.
#
#    The migration is a no-op for this template's threat model: it enables
#    RLS on 10 tables that are only readable via the gbrain role, which
#    owns the tables (Postgres table owners bypass RLS by default) and is
#    not exposed via PostgREST. We detect the failure, mark v24 as applied
#    in gbrain's `config` table, and re-run init to apply v25+ normally.
# ---------------------------------------------------------------------------
run_gbrain_init() {
  local log_file="/tmp/gbrain-init.$$.log"
  if gbrain init --url "$DATABASE_URL" --non-interactive 2>&1 | tee "$log_file"; then
    rm -f "$log_file"
    return 0
  fi

  if ! grep -q 'BYPASSRLS' "$log_file"; then
    log "ERROR: gbrain init failed for a reason other than the known BYPASSRLS limitation. See output above."
    rm -f "$log_file"
    return 1
  fi

  local current_version
  current_version="$(psql "$DATABASE_URL" -tAc "SELECT value FROM config WHERE key='version'" 2>/dev/null | tr -d '[:space:]')"
  if [ "$current_version" != "23" ]; then
    log "ERROR: gbrain init failed at unexpected schema version: '${current_version:-<unset>}' (expected 23 if BYPASSRLS was the only issue)."
    rm -f "$log_file"
    return 1
  fi

  log "Detected gbrain v24 BYPASSRLS limitation. Marking v24 as applied (RLS no-op on Render: gbrain role owns tables and is not exposed via PostgREST)."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE config SET value='24' WHERE key='version' AND value='23';" >/dev/null

  log "Re-running gbrain init to apply remaining migrations..."
  rm -f "$log_file"
  gbrain init --url "$DATABASE_URL" --non-interactive
}

if [ ! -f "${GBRAIN_HOME:-/data/.gbrain}/config.json" ]; then
  log "Running first-time gbrain init..."
  run_gbrain_init
else
  log "gbrain config found, skipping init."
fi

# ---------------------------------------------------------------------------
# 4. Seed the seven GBrain skills into the AlphaClaw skills directory.
#    Only copy on first boot or when the seed is newer (so image upgrades
#    propagate skill updates without clobbering user edits).
# ---------------------------------------------------------------------------
if [ -d /app/skills-seed ]; then
  log "Seeding GBrain skills into $ALPHACLAW_ROOT_DIR/skills..."
  cp -rn /app/skills-seed/* "$ALPHACLAW_ROOT_DIR/skills/" || true
fi

# ---------------------------------------------------------------------------
# 5. Hand off to AlphaClaw.
# ---------------------------------------------------------------------------
log "Starting AlphaClaw..."
exec "$@"
