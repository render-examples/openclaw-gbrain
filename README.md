# OpenClaw + AlphaClaw + GBrain on Render

One-click Render deploy for [OpenClaw](https://github.com/openclaw/openclaw) wrapped in [AlphaClaw](https://github.com/chrysb/alphaclaw), with [GBrain](https://github.com/garrytan/gbrain) pre-installed as a skill pack so your agent has a persistent, hybrid-searchable knowledge brain from the moment it boots.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/renderinc/openclaw-render-template-gbrain)

## What you get

- **AlphaClaw + OpenClaw**, same setup as the [base Render template](https://github.com/chrysb/openclaw-render-template): browser-based setup wizard, watchdog, in-app updates handled by Render.
- **GBrain**, a Postgres-native knowledge brain with hybrid search (vector + keyword + RRF fusion + multi-query expansion), running on embedded **PGLite** so the brain lives entirely in-process — no external database to manage.
- **GBrain skill pack** pre-seeded into `$ALPHACLAW_ROOT_DIR/skills` (ingest, query, maintain, enrich, briefing, install, and more). OpenClaw discovers them automatically on first boot.
- **One container, one disk.** No external Postgres, no second billing line, no second dashboard.

## What this template provisions

| Resource | Plan | Notes |
| --- | --- | --- |
| Web service (Docker) | Standard (2 GB) | AlphaClaw + OpenClaw + GBrain CLI. Standard is the minimum that fits the gateway without OOM. |
| Persistent disk | 10 GB at `/data` | AlphaClaw state, OpenClaw memory index, GBrain PGLite brain file, GBrain config. |

Estimated cost: about $25/mo for Standard web + 10 GB disk at current Render pricing. Compare to AlphaClaw on Railway + Supabase Pro at ~$85/mo + $25/mo. Check [render.com/pricing](https://render.com/pricing) for current rates.

## Before you deploy

You need two API keys:

| Key | Used by | Where to get it |
| --- | --- | --- |
| `OPENAI_API_KEY` | GBrain embeddings (`text-embedding-3-large`) | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| `ANTHROPIC_API_KEY` | GBrain multi-query expansion + LLM chunking (Haiku) | [console.anthropic.com](https://console.anthropic.com) |

Both are required by this template's entrypoint. If you want to run GBrain in degraded mode (keyword search only, no embeddings), remove the `require_env` checks in `entrypoint.sh` before deploying.

Initial embedding cost is roughly $4-5 per 7,500 pages.

## Deploy

1. Click the **Deploy to Render** button above.
2. Render provisions the web service and disk from `render.yaml`.
3. On the web service config screen, fill in `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`. `SETUP_PASSWORD` and `OPENCLAW_GATEWAY_TOKEN` are generated automatically.
4. Wait for the first deploy. The entrypoint will:
   1. Run `gbrain init --pglite` to create the brain file at `/data/.gbrain/brain.pglite` and apply the schema.
   2. Seed the GBrain skills into `/data/skills`.
   3. Start AlphaClaw.
5. Visit your Render URL, enter `SETUP_PASSWORD`, and complete the AlphaClaw welcome wizard.

## First conversation with your brain

Once the welcome wizard finishes, your agent already knows how to use GBrain. Try:

```
You: How many pages are in the brain right now?
You: Import the markdown files at <some path on the disk or a git repo>
You: Search the brain for everything we know about <topic>
You: Give me a briefing for tomorrow
```

OpenClaw reads the skill files in `/data/skills`, picks the right `gbrain` command, and runs it. You do not need to touch the CLI.

## Importing your existing knowledge base

GBrain is designed to ingest your existing markdown. Two patterns work well on Render:

**Option A: paste in chat.** Drop markdown into AlphaClaw's chat; the `ingest` skill writes it to the brain.

**Option B: git pull on the persistent disk.** SSH into the service (`render ssh`) and clone your knowledge repo into `/data/repos/<name>`, then in chat: "Import the markdown at `/data/repos/<name>`." The `install` skill handles `gbrain sync --watch` setup if you want incremental sync.

Binary attachments (images, PDFs, audio) are not supported on this template. GBrain's `files` commands assume Supabase Storage; we would need to add Render Object Storage support upstream to wire those up. Text-only is the v1 scope.

## What is in the box

```
.
├── render.yaml         # Render Blueprint: web service + disk (project-grouped)
├── Dockerfile          # AlphaClaw (Node) + GBrain (Bun, installed from GitHub)
├── entrypoint.sh       # gbrain init (PGLite), skills seed, exec alphaclaw
├── package.json        # Pins @chrysb/alphaclaw
└── README.md
```

The skills themselves are not committed here. They are pulled from the GBrain repo at Docker build time, staged into `/app/skills-seed`, and copied to `/data/skills` on first boot. The skills always match the GBrain version you are running (pinned by SHA via the `GBRAIN_REF` build arg in the Dockerfile).

## Updating

- **AlphaClaw / OpenClaw**: In-app updates are disabled for Render-managed deploys as of AlphaClaw 0.9.0. Bump `@chrysb/alphaclaw` in `package.json` and redeploy.
- **GBrain**: The image installs GBrain at the commit pinned by the `GBRAIN_REF` build arg in the Dockerfile. To upgrade, bump `GBRAIN_REF` to a newer commit from [garrytan/gbrain](https://github.com/garrytan/gbrain) and redeploy. On boot, `gbrain init` is idempotent and applies any pending schema migrations.
- **Schema migrations**: `gbrain init` only runs on the first boot of a fresh disk (gated by the presence of `/data/.gbrain/config.json`). To force a re-run after a major GBrain upgrade, `render ssh` in and execute `gbrain apply-migrations --yes --non-interactive`.

## Why PGLite instead of Render Managed Postgres?

An earlier iteration of this template provisioned a Render Postgres alongside the web service. It does not work: several GBrain schema migrations require the connecting role to hold the `BYPASSRLS` attribute (v24, v29, v31), and migration v35 requires superuser to `CREATE EVENT TRIGGER`. Render Managed Postgres never grants either to user roles, so GBrain's schema cannot fully apply against a Render Postgres instance.

PGLite ([@electric-sql/pglite](https://github.com/electric-sql/pglite)) is GBrain's default engine: Postgres compiled to WebAssembly, running in-process, with `pgvector` and `pg_trgm` bundled in. Every BYPASSRLS-gated migration is a hardcoded no-op on PGLite, and there is no separate role hierarchy to constrain `CREATE EVENT TRIGGER`. The trade-off is that the brain is single-instance (only the running container can open the brain file), which already matches this template's persistent-disk architecture.

## Troubleshooting

**Container OOMs on startup.** The Standard plan (2 GB) is the floor for OpenClaw's gateway. Do not downgrade to Starter.

**Embeddings stuck at 0.** Check the service logs for OpenAI rate limit errors. GBrain backs off automatically. If `OPENAI_API_KEY` is missing or invalid, search still works in keyword-only mode.

**Skills not appearing in OpenClaw.** Confirm `/data/skills` is populated after first boot (`render ssh` into the service and `ls /data/skills`). The entrypoint uses `cp -rn` so it will never overwrite user edits, but it also will not re-seed if the directory exists.

**Brain file missing after redeploy.** The brain lives at `/data/.gbrain/brain.pglite`. Confirm the persistent disk is still attached and mounted at `/data`. If you accidentally recreate the disk, the brain is gone — restore from the latest Render disk snapshot.

## Limitations

- **Single-instance only.** PGLite (like the disk it lives on) can only be opened by one process at a time. This template does not support horizontal scaling or zero-downtime deploys. Render restarts the container on deploy, which briefly drops connections.
- **Binary attachments**: not supported. GBrain's `files` subsystem expects Supabase Storage.
- **Multi-region**: this template deploys to `oregon`. Change `region` in `render.yaml` if you need a different region; the disk must match the service.
- **Backup**: AlphaClaw handles application-level disk backups via cron. Render disk snapshots provide block-level backups. Verify both are working before you put real knowledge into the brain.

## License

MIT for the template itself. AlphaClaw, OpenClaw, and GBrain each ship under their own licenses (MIT at last check). See upstream repos.
