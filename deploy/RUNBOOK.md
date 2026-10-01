# Operations Runbook (Phase 5)

## Topology

A single VM (Hetzner CX41 or similar) running Docker. Five long-lived
containers managed by `docker-compose.yml`:

- **caddy** — TLS termination + reverse proxy (ports 80/443).
- **api** — the Lyric API server; launches ephemeral `claude-code:*` runner
  containers via the mounted Docker socket.
- **frontend** — the Vite/React app, built in a Docker multi-stage build
  (`frontend/Dockerfile`) and served as static files by nginx.
- **postgres** — the Postgres database (`pg_data` volume); see "Postgres".
- **maintenance** — calls the API's maintenance endpoints on a schedule
  (`deploy/maintenance.sh`); see "Maintenance poller".

A one-shot **migrate** container applies the Postgres schema on every
deploy and exits before the API starts.

Runner containers are **ephemeral**: one per message, removed after the run.
Session state lives on Docker volumes (`session-*` workspaces, `user-*-home`
credentials), not in the containers.

## First-time setup

```sh
sudo ./install-docker.sh                 # install Docker + build all five runner images
sudo mkdir -p /opt/cloud-agents && sudo rsync -a . /opt/cloud-agents/
cd /opt/cloud-agents/deploy
cp .env.example .env && edit .env        # set ENCRYPTION_KEY, CLOUD_AGENTS_API_TOKEN, the CLOUD_AGENTS_PG_* passwords
docker compose up -d
```

Set your domain in `Caddyfile` (replace `agent.example.com`) before starting.

> **Optional — GitHub OAuth sign-in:** set `CLOUD_AGENTS_GITHUB_CLIENT_ID` and
> `CLOUD_AGENTS_GITHUB_CLIENT_SECRET` in `.env` (see `.env.example`) to enable
> "Sign in with GitHub" and enforce its login guard. Create the OAuth App at
> GitHub -> Settings -> Developer settings -> OAuth Apps, with "Authorization
> callback URL" set to `https://<your-domain>/auth/callback`. Leave both
> empty (the default) to run with no sign-in requirement, same as before
> these existed. Or, idiomatically, set `LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTID`
> / `LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTSECRET` /
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

> **Optional — corporate-proxy CA propagation into runner containers (#648):**
> set `NODE_EXTRA_CA_CERTS` and/or `NODE_TLS_REJECT_UNAUTHORIZED` in `.env` to
> have every ephemeral runner container trust a corporate/proxy root CA (e.g.
> Zscaler TLS inspection) at session start — `docker_manager.l`'s
> `createRunnerContainer` reads both from the `api` service's own process
> environment and forwards them into each runner it spawns. `api` talks to
> Docker over the host socket mount (`/var/run/docker.sock`), a
> docker-outside-of-docker topology — so `NODE_EXTRA_CA_CERTS` must be set to
> a path that exists **on this VM's own filesystem** (the Docker host), not a
> path inside the `api` container; that value is bind-mounted straight into
> each runner as `/etc/host-ca.pem:ro`, and the bind-mount source is resolved
> by the host's `dockerd`, which never sees `api`'s container filesystem.
> Leave both unset (the default) for no change from today's behavior.

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
  design. Startup does not reset sessions any more, because with several API
  instances another one may be driving them
  (`docs/phase11-postgres-tenancy.md` §5.3a). A run whose instance died
  stops renewing its heartbeat; two minutes later the maintenance sweep
  (`POST /api/maintenance/reap`, called every minute by the `maintenance`
  container) stops its container, marks the run failed and returns the
  session to `IDLE`. To free such sessions sooner after a restart, call that
  endpoint by hand once two minutes have passed:
  `curl -X POST -H "Authorization: Bearer $CLOUD_AGENTS_API_TOKEN" https://<domain>/api/maintenance/reap`. On the
  next message the API recreates a fresh container from the session's
  volumes.
- **API crash loop:** check `docker compose logs api`. `ENCRYPTION_KEY` is
  required by `docker-compose.yml`'s `${ENCRYPTION_KEY:?...}` guard, which
  fails at `docker compose` parse/start time if unset — but nothing in the
  Lyric source actually reads this variable today, so don't expect an
  app-level error message pointing at it; the compose-level guard is the
  only enforcement.

- **API exits with `FATAL: Postgres self-check failed`:** the message names
  the problem (a missing role, a role that can bypass row-level security).
  Check `docker compose logs postgres migrate`. A password with characters
  other than letters and digits is rejected before the data directory is
  created, so fixing the variable is enough. If provisioning failed for
  another reason after that, the volume is left without the roles; then
  `docker compose down` and `docker volume rm deploy_pg_data` before starting
  again. Only do that while Postgres holds no data (before the cut-over).

## Postgres

The `postgres` service creates the `cloudagents` database and its roles on
first start from `deploy/postgres/provision.sql`, with the passwords in
`.env`; later starts leave the volume alone. The `migrate` service applies
the schema as `cloudagents_owner` on every deploy (a no-op when current) and
the API starts after it succeeds, connected as `cloudagents_app`. Until the
cut-over (`docs/phase11-postgres-tenancy.md` §9, slice E) the API still
stores everything in SQLite.

- Change a password: `docker compose exec postgres psql -U postgres -c
  "ALTER ROLE cloudagents_app PASSWORD '<new>'"`, update `.env`, then
  `docker compose up -d`.
- A `psql` shell: `docker compose exec postgres psql -U postgres -d cloudagents`.

## Maintenance poller

The `maintenance` container POSTs the API's operator-only maintenance
endpoints with `CLOUD_AGENTS_API_TOKEN`: `reap`, `trigger-jobs`,
`drain-graph-ingest` and `observe` every 60 s, and `ledger-sync` every 300 s.
Each interval is set by a `MAINTENANCE_*_SECONDS` variable in `.env` (0
disables it); `COOLIFY.md` "Maintenance poller" lists them. Every call and
its result is logged: `docker compose logs maintenance`.

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

## Persistent state

All API state lives in two places, both outside the api container so a
redeploy or rebuild never touches them:

- `CLOUD_AGENTS_DATA_DIR` (host directory, default `/var/lib/cloud-agents`):
  the SQLite database `cloud-agents.db` (plus its `-wal`/`-shm` files),
  `artifacts/` and `attachments/`. It is bind-mounted into the api container
  at the same path, because attachment directories are re-mounted into runner
  containers by the host's dockerd and so must resolve identically on both
  sides. Changing `CLOUD_AGENTS_DATA_DIR` after first deploy points the api at
  an empty directory: move the old directory's contents first.
- The `user_data` named volume (`/user-home`): per-user harness credentials.

Per-session workspace and home volumes are separate named Docker volumes and
also survive redeploys.

### Upgrading from a deployment without a data directory

Before this layout, the database, artifacts and attachments defaulted to
paths inside the api container (`/app/cloud-agents.db`,
`/app/cloud-agents-artifacts`, `/app/cloud-agents-attachments`) and were
discarded on every redeploy. To keep the state of the currently running
container, copy it out BEFORE deploying the new compose file. Stop the api
first so nothing writes while you copy (a copy of a live WAL database can be
torn); `docker cp` works on a stopped container. Do not remove the container
until the copy has been verified:

```sh
docker compose stop api
API=$(docker compose ps -a -q api)
sudo mkdir -p /var/lib/cloud-agents
for f in cloud-agents.db cloud-agents.db-wal cloud-agents.db-shm; do
    sudo docker cp "$API:/app/$f" /var/lib/cloud-agents/ || echo "no $f (fine for -wal/-shm)"
done
sudo docker cp "$API:/app/cloud-agents-artifacts" /var/lib/cloud-agents/artifacts || true
sudo docker cp "$API:/app/cloud-agents-attachments" /var/lib/cloud-agents/attachments || true
# Must print "ok"; if it does not, or cloud-agents.db was not copied, stop here.
docker run --rm -v /var/lib/cloud-agents:/data alpine sh -c \
    'apk add --no-cache sqlite >/dev/null && sqlite3 /data/cloud-agents.db "PRAGMA integrity_check"'
```

Then deploy the new compose file. The artifacts/attachments copies fail
harmlessly when a deployment never stored any.

Artifact and attachment rows store only file names; their directories are
derived from `CLOUD_AGENTS_ARTIFACTS_DIR`/`CLOUD_AGENTS_ATTACHMENTS_DIR` at
read time, so moved files are found under the new location.

## Backups

`backup.sh` runs nightly (cron example inside the script) and writes four
archives per run, keeping the 14 most recent of each:

- `db-<stamp>.db.gz`: an online `sqlite3 .backup` snapshot (consistent while
  the api is writing), integrity-checked before it is kept;
- `files-<stamp>.tar.gz`: `artifacts/` and `attachments/`;
- `user-home-<stamp>.tar.gz`: the `user_data` volume;
- `pg-<stamp>.dump`: `pg_dump` of the `cloudagents` database (custom
  format), checked with `pg_restore --list` before it is kept.

It exits non-zero if the database or volume is missing rather than archiving
nothing. The database step pulls the `sqlite` package into an `alpine`
container, so it needs registry access at run time. Copy archives off-server
or use Hetzner volume snapshots. Restore with the api stopped:

```sh
docker compose stop api
gunzip -c db-<stamp>.db.gz | sudo tee /var/lib/cloud-agents/cloud-agents.db >/dev/null
sudo rm -f /var/lib/cloud-agents/cloud-agents.db-wal /var/lib/cloud-agents/cloud-agents.db-shm
sudo tar xzf files-<stamp>.tar.gz -C /var/lib/cloud-agents
docker run --rm -v deploy_user_data:/data -v "$PWD:/backup" alpine \
    tar xzf /backup/user-home-<stamp>.tar.gz -C /data
docker compose start api
```

Restore Postgres into the running `postgres` container with the API stopped:

```sh
docker compose stop api maintenance
docker compose exec -T postgres pg_restore -U postgres -d cloudagents --clean --if-exists < pg-<stamp>.dump
docker compose start api maintenance
```

## Monitoring

- `/api/health` should return 200 and confirm Docker connectivity.
- Point UptimeRobot / Healthchecks.io at the health endpoint.
- Docker `json-file` log driver with rotation (`max-size`, `max-file`) keeps
  disk bounded.
