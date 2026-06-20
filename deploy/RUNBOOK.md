# Operations Runbook (Phase 5)

## Topology

A single VM (Hetzner CX41 or similar) running Docker. Three long-lived
containers managed by `docker-compose.yml`:

- **caddy** — TLS termination + reverse proxy (ports 80/443).
- **api** — the Lyric API server; launches ephemeral `claude-code:*` runner
  containers via the mounted Docker socket.
- **frontend** — static prototype served by nginx.

Runner containers are **ephemeral**: one per message, removed after the run.
Session state lives on Docker volumes (`session-*` workspaces, `user-*-home`
credentials), not in the containers.

## First-time setup

```sh
sudo ./install-docker.sh                 # install Docker + build claude-code:base
sudo mkdir -p /opt/cloud-agents && sudo rsync -a . /opt/cloud-agents/
cd /opt/cloud-agents/deploy
cp .env.example .env && edit .env        # set ENCRYPTION_KEY, CLOUD_AGENTS_WHITELIST
docker compose up -d
```

Set your domain in `Caddyfile` (replace `agent.example.com`) before starting.

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
  design. On the next message the API recreates a container from the session's
  volumes. Any session left in `RUNNING`/`WARM` should be reset to `IDLE` by the
  startup recovery routine (Phase 2).
- **API crash loop:** check `docker compose logs api`; most startup failures are
  a missing required env var (`ENCRYPTION_KEY`) — config is fail-fast.

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
