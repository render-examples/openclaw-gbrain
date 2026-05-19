# OpenClaw + AlphaClaw + GBrain (Render template)
#
# Bakes AlphaClaw (Node) and GBrain (Bun) into a single image. On first boot,
# the entrypoint enables pgvector + pg_trgm on the attached Postgres and runs
# `gbrain init --url $DATABASE_URL` to apply the schema migration. After that,
# it hands off to `alphaclaw start`, which runs the AlphaClaw watchdog and
# the OpenClaw gateway.

FROM node:22-slim

# System deps:
#   - git, curl: required by AlphaClaw + GBrain install paths
#   - procps: watchdog uses ps for process supervision
#   - cron: AlphaClaw schedules backup/maintenance jobs
#   - postgresql-client: psql for the one-time CREATE EXTENSION step
#   - ca-certificates, unzip: needed for the bun installer + TLS to Postgres
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      procps \
      cron \
      postgresql-client \
      ca-certificates \
      unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install bun (GBrain ships as a Bun package).
# Pin to a known-good version so builds are reproducible.
ENV BUN_INSTALL=/usr/local/bun
ENV PATH=$BUN_INSTALL/bin:/app/node_modules/.bin:$PATH
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.1.34" \
    && bun --version

# Install AlphaClaw (which pulls in OpenClaw as a managed dependency).
# Keeping this in its own layer so AlphaClaw version bumps don't bust the bun layer.
COPY package.json ./
RUN npm install --omit=dev

# Install GBrain globally so the `gbrain` CLI is on PATH for the entrypoint
# and for any skills that shell out to it.
RUN bun add -g gbrain

# Skill pack: GBrain's seven fat-markdown skills (ingest, query, maintain,
# enrich, briefing, migrate, install). They ship inside the gbrain npm package
# under skills/. We extract them at build time and stage them in
# /app/skills-seed; the entrypoint copies them into $ALPHACLAW_ROOT_DIR/skills
# on first boot, since the persistent disk isn't mounted during build.
RUN mkdir -p /app/skills-seed \
    && GBRAIN_SKILLS_DIR="$BUN_INSTALL/install/global/node_modules/gbrain/skills" \
    && if [ ! -d "$GBRAIN_SKILLS_DIR" ]; then \
         GBRAIN_SKILLS_DIR="$(find "$BUN_INSTALL" -type d -path '*/gbrain/skills' 2>/dev/null | head -n1)"; \
       fi \
    && if [ -n "$GBRAIN_SKILLS_DIR" ] && [ -d "$GBRAIN_SKILLS_DIR" ]; then \
         echo "Seeding skills from $GBRAIN_SKILLS_DIR"; \
         cp -r "$GBRAIN_SKILLS_DIR/." /app/skills-seed/; \
       else \
         echo "ERROR: could not locate gbrain skills/ directory under $BUN_INSTALL" >&2; \
         exit 1; \
       fi

# Entrypoint: prepares the database, seeds skills, then execs AlphaClaw.
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV ALPHACLAW_ROOT_DIR=/data
ENV NODE_ENV=production

EXPOSE 10000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["alphaclaw", "start"]
