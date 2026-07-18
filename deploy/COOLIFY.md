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
(`src/handlers/sessions.l:759`) only probes SQLite, there's no Docker
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
runtime beyond getting built.

**Only `claude-code-base` is enabled by default** — `codex-base`/
`opencode-base`/`gemini-base` are commented out. This isn't just about
build time: `docker compose build` (how Coolify invokes it, no service
argument) builds every enabled service in one shot, and a failure in *any
one* fails the whole command — which blocks `api`/`frontend`/`caddy` from
deploying too, not just the broken harness. This happened for real:
`Dockerfile.codex`'s `npm install -g @openai/codex` step failed mid-build
and took the entire deploy down with it, even though nothing about
`api`/`frontend` had changed. Before uncommenting a harness, confirm its
Dockerfile actually builds cleanly on its own first —
`docker build -f docker/Dockerfile.codex docker` (swap in the relevant
Dockerfile) — so a bad runner image can't block every future deploy of the
whole app.

Enabled services show as **"Exited (0)"** in Coolify's service list —
that's the intended behavior, not a failure; only the built image matters.
The runner Dockerfiles force `--platform=linux/amd64`, so building on an
arm64 Coolify host means QEMU emulation — noticeably slower, another
reason to only enable the harnesses you actually use.

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
