# Operations Runbook (Phase 5)

## Topology

A single VM (Hetzner CX41 or similar) running Docker. Three long-lived
containers managed by `docker-compose.yml`:

- **caddy** — TLS termination + reverse proxy (ports 80/443).
- **api** — the Lyric API server; launches ephemeral `claude-code:*` runner
  containers via the mounted Docker socket.
- **frontend** — the Vite/React app, built in a Docker multi-stage build
  (`frontend/Dockerfile`) and served as static files by nginx.

Runner containers are **ephemeral**: one per message, removed after the run.
Session state lives on Docker volumes (`session-*` workspaces, `user-*-home`
credentials), not in the containers.

## First-time setup

```sh
sudo ./install-docker.sh                 # install Docker + build all four runner images
sudo mkdir -p /opt/cloud-agents && sudo rsync -a . /opt/cloud-agents/
cd /opt/cloud-agents/deploy
cp .env.example .env && edit .env        # set ENCRYPTION_KEY, CLOUD_AGENTS_WHITELIST
docker compose up -d
```

Set your domain in `Caddyfile` (replace `agent.example.com`) before starting.

> **Optional — GitHub OAuth sign-in:** set `CLOUD_AGENTS_GITHUB_CLIENT_ID` and
> `CLOUD_AGENTS_GITHUB_CLIENT_SECRET` in `.env` (see `.env.example`) to enable
> "Sign in with GitHub" and enforce its login guard. Create the OAuth App at
> GitHub -> Settings -> Developer settings -> OAuth Apps, with "Authorization
> callback URL" set to `https://<your-domain>/auth/callback`. Leave both
> empty (the default) to run with no sign-in requirement, same as before
> these existed. Or, idiomatically, set `LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENT_ID`
> / `LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENT_SECRET` /
> `LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_WHITELIST` instead — a Lyric `config`
> block (D046) that takes priority over the `CLOUD_AGENTS_*` names above when
> set. If you use it for client id/secret, set the whitelist one too (or keep
> `CLOUD_AGENTS_WHITELIST` set): an empty whitelist on either path means open
> access to any authenticated GitHub user, not "no one".

> **Optional — `restricted` network policy:** to use profiles with the
> `restricted` network policy, first create the internal egress network named
> by `CLOUD_AGENTS_RESTRICTED_NETWORK` in `.env`, e.g.
> `docker network create --internal egress-net`. If it isn't created, a
> `restricted` profile fails closed to full isolation (no network) rather than
> silently opening the network. See `docs/phase5-deployment.md` for details.

## Routine operations

| Task | Command |
|------|---------|
| View logs | `docker compose logs -f api` |
| Restart API | `docker compose restart api` |
| Health check | `curl -f https://<domain>/api/health` |
| List runner containers | `docker ps --filter name=session-` |
| Prune stale runners | `docker container prune -f` |
| Disk usage | `docker system df` |
| Reclaim space | `docker image prune -f && docker volume prune -f` (⚠ see below) |

⚠ **Never** prune `user-*-home` volumes — they hold user credentials. Only
prune `session-*` workspace volumes for deleted sessions.

## Recovery

- **Docker daemon restarted / VM rebooted:** runner containers are gone by
  design. Startup (`src/main.l`) now terminates any stranded containers it
  still finds a record of, then calls `CloudAgents.SessionStore.
  recoverDanglingSessions()` (`recoverDanglingSessionsSql` in
  `src/db/db_client.l`) to reset sessions left stuck `RUNNING`/`WARM` back to
  `IDLE` — this used to be designed but not wired in anywhere (see
  `docs/review-2026-07-03-followup.md` finding #4); it's genuinely called
  from startup now and covered by `CloudAgents.SessionTests`. On the next
  message the API recreates a fresh container from the session's volumes.
- **API crash loop:** check `docker compose logs api`. `ENCRYPTION_KEY` is
  required by `docker-compose.yml`'s `${ENCRYPTION_KEY:?...}` guard, which
  fails at `docker compose` parse/start time if unset — but nothing in the
  Lyric source actually reads this variable today, so don't expect an
  app-level error message pointing at it; the compose-level guard is the
  only enforcement.

## Rollback

If a deploy goes bad (new image fails health checks, crash-loops, or
regresses behavior):

```sh
cd /opt/cloud-agents
git log --oneline -5                     # find the last known-good commit/tag
git checkout <previous-good-ref>
cd deploy
docker compose up -d --build             # rebuilds api/frontend from the reverted source
```

There's no image registry or version pinning in this setup — `docker compose
up -d --build` always rebuilds from whatever's checked out locally, so
rolling back is rolling back the checkout, then rebuilding. Runner container
images (`claude-code:base`, etc.) are unaffected by an API/frontend rollback
and don't need rebuilding unless the rollback also reverts `docker/`.

## Backups

`backup.sh` archives the `user_data` volume nightly (cron example inside the
script) and keeps the 14 most recent archives. Copy archives off-server or use
Hetzner volume snapshots. Restore with:

```sh
docker run --rm -v deploy_user_data:/data -v "$PWD:/backup" alpine \
    tar xzf /backup/user-home-<stamp>.tar.gz -C /data
```

## Monitoring

- `/api/health` should return 200 and confirm Docker connectivity.
- Point UptimeRobot / Healthchecks.io at the health endpoint.
- Docker `json-file` log driver with rotation (`max-size`, `max-file`) keeps
  disk bounded.
