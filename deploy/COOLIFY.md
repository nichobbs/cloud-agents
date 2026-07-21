# Deploying to Coolify

An alternative to the standalone-VM setup in `RUNBOOK.md`, for running this
app on a Coolify instance that also hosts other projects. Uses
`docker-compose.coolify.yml` / `Caddyfile.coolify` instead of
`docker-compose.yml` / `Caddyfile` — see the comments at the top of that
compose file for what differs and why.

## Setup

1. **Connect the repo.** In Coolify: Settings → Sources → add a GitHub App
   (Coolify pre-fills the webhook/homepage/redirect URLs) → install it on
   this repo.
2. **Create the resource.** New Resource → pick that source → select the
   repo and branch → build pack **Docker Compose** → set the compose file
   path to `deploy/docker-compose.coolify.yml`.
3. **Set environment variables** in the resource's Environment Variables tab
   (see `.env.example` for what each does):
   - `ENCRYPTION_KEY` (required — generate with `openssl rand -base64 32`)
   - `CLOUD_AGENTS_WHITELIST` (optional)
   - `CLOUD_AGENTS_GITHUB_CLIENT_ID`, `CLOUD_AGENTS_GITHUB_CLIENT_SECRET`
     (optional — from a GitHub OAuth App with its callback URL set to
     `https://<your-domain>/auth/callback`; leave both empty to run with no
     sign-in requirement)
   - `CLOUD_AGENTS_RESTRICTED_NETWORK`, `CLOUD_AGENTS_EGRESS_PROXY` (optional,
     only needed for the `restricted` network policy)
   - `SERVICE_FQDN_CADDY_80` — Coolify manages this one itself once it
     detects the bare reference in the compose file; set your domain there,
     or leave it for Coolify to assign a subdomain.
4. **Enable auto-deploy** on push to whichever branch you want live. Every
   push fires the GitHub App's webhook, which Coolify verifies and redeploys
   from, posting a commit status back to GitHub.

## Docker socket

`api` still needs `/var/run/docker.sock` mounted to launch runner
containers as siblings of itself — same as the standalone-VM setup, but the
blast radius is bigger here: this host also runs your other Coolify
projects, and the mounted socket gives `api` (and anything that compromises
it) root-equivalent control over their containers too, not just this app's.
Coolify has no built-in more-restricted transport for this as of writing
(see the PR discussion / commit history for context) — if that matters more
than convenience, put this app on its own VM instead of a shared Coolify
host.

Coolify has had bugs where a file-path bind mount lands as a directory
instead of the real file/socket. After the first deploy, confirm it worked:

```sh
docker compose exec api test -S /var/run/docker.sock && echo ok
```

If that fails, the mount didn't come through as a socket — and note
`/api/health` won't tell you that: `checkHealth()`
(`src/handlers/sessions.l`) only probes SQLite, there's no Docker
connectivity check anywhere in the stack. Uptime monitoring pointed at
`/api/health` (per `RUNBOOK.md`) will report healthy even with a broken
`docker.sock` mount — the `test -S` command above is the only way to catch
this failure mode.

## Runner base images

`docker-compose.coolify.yml` can build these directly (`claude-code-base`,
`codex-base`, `opencode-base`, `gemini-base`) — no manual `docker build` on
the host needed for whichever are enabled. Each is a normal Compose service
with `build:` pointed at the matching `docker/Dockerfile*`, but an explicit
`image:` tag overriding Compose's default `<project>-<service>` naming so
the built image lands under the exact name `imageForHarness()`
(`src/docker_manager.l`) looks for (`claude-code:base`, etc.) — and
`entrypoint: ["true"]` + `restart: "no"` so the "service" does nothing at
runtime beyond getting built. `claude-code-base` alone uses `context: .`
(repo root) rather than `./docker` like the other three: its Dockerfile
builds `cloud-agents-shim` in its own build stage from `shim/`, so it needs
both `docker/` and `shim/` in one build context (#601 — this used to be
staged externally by `scripts/build-docker.sh` before `docker build` ran,
which worked for a local `make docker` but not for Coolify's `docker compose
build`, since nothing there ever ran that staging step; it's now built
inside the Dockerfile itself, so any orchestrator works standalone).

**Only `claude-code-base` is active by default.** `codex-base`/
`opencode-base`/`gemini-base` are gated behind Compose `profiles:` — this
isn't just about build time: `docker compose build` (how Coolify invokes
it, no service argument) builds every *active* service in one shot, and a
failure in *any one* fails the whole command, which blocks
`api`/`frontend`/`caddy` from deploying too, not just the broken harness.
This happened for real: `Dockerfile.codex`'s `npm install -g @openai/codex`
step failed mid-build and took the entire deploy down with it, even though
nothing about `api`/`frontend` had changed.

A profiled service (`profiles: ["codex"]`, etc.) is skipped entirely —
build included — unless its profile is active, via the `COMPOSE_PROFILES`
env var (comma-separated) or a `--profile` flag; Coolify's own deploy
passes neither, so these three stay off unless you opt in. To enable one:

1. **Confirm its Dockerfile actually builds standalone first** —
   `docker build -f docker/Dockerfile.codex docker` (swap in the relevant
   Dockerfile) — before wiring it into the shared deploy at all. Don't let
   an untested runner image risk blocking every future deploy of the whole
   app.
2. Set `COMPOSE_PROFILES` in Coolify's Environment Variables tab to the
   harness(es) you want built automatically, e.g. `codex` or
   `codex,gemini`. `claude-code-base` has no `profiles:` key, so it's
   always active regardless of this setting.

### Picking up a newer Lyric release

`claude-code-base`'s Dockerfile (`docker/Dockerfile`) auto-resolves the
latest `lyric-lang` release at build time by default rather than pinning a
version (`--build-arg LYRIC_VERSION=X.Y.Z` still overrides this). Like any
other `RUN` instruction, that resolution is cached — once a layer for it
exists, an ordinary redeploy reuses it and keeps whatever version it first
resolved to, rather than re-checking for a newer release. A normal push
only invalidates that cache if something upstream changed (`shim/`,
`MIN_LYRIC_VERSION`, or the base image digest) — otherwise you're on
whatever "latest" resolved to the first time this image built on this host.

To force a fresh resolution: Coolify's per-deployment **"Force rebuild
(without cache)"** option (also settable persistently via the app's
Build → Advanced → **"Disable Build Cache"** toggle) adds Docker's
`--no-cache` flag, which re-runs every layer including this one. There have
been open Coolify bugs where this toggle doesn't take effect on
webhook-triggered auto-deploys specifically (see
[coollabsio/coolify#6133](https://github.com/coollabsio/coolify/issues/6133)) —
if a manual "Force rebuild" from Coolify's UI doesn't pick up a newer
release either, that's a Coolify-side caching bug to chase, not something
this Dockerfile can work around.

Enabled services show as **"Exited (0)"** in Coolify's service list —
that's the intended behavior, not a failure; only the built image matters.
Each runner-image service also sets Coolify's documented `exclude_from_hc:
true` flag (#516) so Coolify's own healthcheck evaluation skips it rather
than treating the non-restarting exited container as an unhealthy/failed
deployment signal — see
[Coolify's Docker Compose docs](https://coolify.io/docs/knowledge-base/docker/compose),
which use the same one-shot-service shape (a `migrate` container) as their
own example. The runner Dockerfiles force `--platform=linux/amd64`, so
building on an arm64 Coolify host means QEMU emulation — noticeably
slower, another reason to only enable the harnesses you actually use.

## Backups

`backup.sh` defaults to volume name `deploy_user_data` — Compose's
`<project>_<volume>` naming when run from a directory literally called
`deploy`, which is how the standalone-VM setup invokes it. Coolify assigns
its own project name, so the real volume will be named differently. Find it
with `docker volume ls | grep user_data` after first deploy, then either
edit `USER_DATA_VOLUME` in your cron invocation or export it before running
`backup.sh` — the script accepts it as an override
(`VOLUME="${USER_DATA_VOLUME:-deploy_user_data}"`). Skipping this doesn't
error: `docker run -v <wrong-name>:...` silently creates and archives an
empty volume, so backups would look like they're working while being empty.

## Everything else

Routine operations and recovery notes in `RUNBOOK.md` apply unchanged —
they operate on the same container roles regardless of which compose file
brought them up.
