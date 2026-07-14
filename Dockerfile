# OpenClaw + AlphaClaw + GBrain (Render template, PGLite engine)
#
# Bakes AlphaClaw (Node) and GBrain (Bun) into a single image. The GBrain
# brain runs as embedded PGLite (Postgres-in-WASM via @electric-sql/pglite)
# against a file on the persistent disk — no external Postgres required.
# On first boot the entrypoint runs `gbrain init --pglite --non-interactive`
# to apply the schema, then execs `alphaclaw start`, which runs the
# AlphaClaw watchdog and the OpenClaw gateway.

FROM node:22-slim

# System deps:
#   - git, curl: required by AlphaClaw + GBrain install paths
#   - procps: watchdog uses ps for process supervision
#   - cron: AlphaClaw schedules backup/maintenance jobs
#   - ca-certificates, unzip: needed for the bun installer + TLS for API calls
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      procps \
      cron \
      ca-certificates \
      unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install bun (GBrain ships as a Bun package).
# Pin to a known-good version so builds are reproducible.
# GBrain's package.json requires "bun": ">=1.3.10".
ENV BUN_INSTALL=/usr/local/bun
ENV PATH=$BUN_INSTALL/bin:/app/node_modules/.bin:$PATH
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.13" \
    && bun --version

# Install AlphaClaw (which pulls in OpenClaw as a managed dependency).
# Keeping this in its own layer so AlphaClaw version bumps don't bust the bun layer.
COPY package.json ./
RUN npm install --omit=dev

# Install GBrain globally so the `gbrain` CLI is on PATH for the entrypoint
# and for any skills that shell out to it.
#
# GBrain is NOT published on npm (the npm package named `gbrain` is an
# unrelated GPU ML library). Install directly from GitHub, pinned to a
# commit SHA for reproducible builds. Bump GBRAIN_REF to upgrade.
#
# The postinstall script tries to run `gbrain apply-migrations` against a
# brain that doesn't exist yet at build time. Skip lifecycle scripts so the
# step is fast and the build log stays clean — the entrypoint runs
# `gbrain init --pglite` at boot, which creates the brain and applies
# migrations against the persistent disk.
ARG GBRAIN_REF=5008b287e47bf791132eedfebf66bdef11e9398c
ENV npm_config_ignore_scripts=true
RUN bun add -g "github:garrytan/gbrain#${GBRAIN_REF}" \
    && gbrain --version || true

# Skill pack: GBrain's fat-markdown skills (ingest, query, maintain, enrich,
# briefing, migrate, install, and ~40 more). They live at the repo root
# under skills/. We stage them in /app/skills-seed; the entrypoint copies
# them into $ALPHACLAW_ROOT_DIR/skills on first boot, since the persistent
# disk isn't mounted during build.
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

# Entrypoint: initializes the PGLite brain, seeds skills, execs AlphaClaw.
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV ALPHACLAW_ROOT_DIR=/data
ENV NODE_ENV=production

EXPOSE 10000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["alphaclaw", "start"]
