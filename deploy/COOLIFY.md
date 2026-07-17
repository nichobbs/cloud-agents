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
containers as siblings of itself — same as the standalone-VM setup, and the
same host-Docker-root-equivalent-access tradeoff applies (see the PR
discussion / commit history for context, since Coolify has no built-in
more-restricted transport for this as of writing).

Coolify has had bugs where a file-path bind mount lands as a directory
instead of the real file/socket. After the first deploy, confirm it worked:

```sh
docker compose exec api test -S /var/run/docker.sock && echo ok
```

If that fails, the mount didn't come through as a socket and the API's
Docker connectivity health check will fail too.

## Runner base images

Coolify only builds the `api` and `frontend` services in the compose file —
it doesn't run `install-docker.sh`. The `claude-code:base` (and other
runner) images that `install-docker.sh` builds on a standalone VM still need
to exist on the Coolify host before sessions can spawn runner containers.
Build them from `docker/` on the host directly (SSH in and run the relevant
`docker build` from `docker/Dockerfile*`) — Coolify's own build only covers
the compose file's services.

## Everything else

Backups (`backup.sh`), routine operations, and recovery notes in
`RUNBOOK.md` apply unchanged — they operate on the same volume names and
container roles regardless of which compose file brought them up.
