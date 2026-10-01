#!/bin/bash
# Smoke test for the deploy images that are not the API: builds
# deploy/postgres.Dockerfile and deploy/maintenance.Dockerfile, then checks
#   - postgres provisions the cloudagents database and roles on first start,
#     and refuses a password that cannot be quoted safely before it creates
#     the data directory;
#   - the maintenance poller refuses to start without a token or with a
#     malformed interval.
# Needs a Docker daemon. Run from anywhere: ./scripts/test-deploy-images.sh
# SKIP_BUILD=1 uses already-built images with the tags below.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_IMAGE=cloud-agents-postgres-test
MAINT_IMAGE=cloud-agents-maintenance-test
GOOD=ca-deploy-test-pg-good
BAD=ca-deploy-test-pg-bad
IDLE=ca-deploy-test-maint-idle
BAD_VOLUME=ca-deploy-test-pg-bad-data

cleanup() {
  docker rm -f "$GOOD" "$BAD" "$IDLE" >/dev/null 2>&1 || true
  docker volume rm -f "$BAD_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ -z "${SKIP_BUILD:-}" ]; then
  docker build -q -f "$REPO_ROOT/deploy/postgres.Dockerfile" -t "$PG_IMAGE" "$REPO_ROOT" >/dev/null
  docker build -q -f "$REPO_ROOT/deploy/maintenance.Dockerfile" -t "$MAINT_IMAGE" "$REPO_ROOT" >/dev/null
fi

echo "== postgres provisions on first start =="
docker run -d --name "$GOOD" -e POSTGRES_PASSWORD=super1 \
  -e CLOUD_AGENTS_PG_OWNER_PASSWORD=owner1 -e CLOUD_AGENTS_PG_APP_PASSWORD=app1 "$PG_IMAGE" >/dev/null
ready=0
for _ in $(seq 1 60); do
  if docker exec "$GOOD" pg_isready -h 127.0.0.1 -U postgres -d cloudagents >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  docker logs "$GOOD" >&2
  echo "FAIL: postgres never became ready" >&2
  exit 1
fi
roles="$(docker exec "$GOOD" psql -U postgres -d cloudagents -tA -c \
  "SELECT string_agg(rolname || ':' || rolcanlogin, ',' ORDER BY rolname) FROM pg_roles WHERE rolname LIKE 'cloudagents_%'")"
expected="cloudagents_app:true,cloudagents_claimer:false,cloudagents_migrator:false,cloudagents_owner:true"
if [ "$roles" != "$expected" ]; then
  echo "FAIL: roles were '$roles', expected '$expected'" >&2
  exit 1
fi
owner="$(docker exec "$GOOD" psql -U postgres -tA -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'cloudagents'")"
if [ "$owner" != "cloudagents_owner" ]; then
  echo "FAIL: cloudagents is owned by '$owner'" >&2
  exit 1
fi
# The app role logs in over TCP with its password.
docker exec -e PGPASSWORD=app1 "$GOOD" psql -h 127.0.0.1 -U cloudagents_app -d cloudagents -tA -c "SELECT 1" >/dev/null
echo "ok"

echo "== postgres refuses an unsafe password before creating the data directory =="
docker volume rm -f "$BAD_VOLUME" >/dev/null 2>&1 || true
docker run -d --name "$BAD" -v "$BAD_VOLUME:/var/lib/postgresql/data" -e POSTGRES_PASSWORD=super1 \
  -e "CLOUD_AGENTS_PG_OWNER_PASSWORD=bad'pw" -e CLOUD_AGENTS_PG_APP_PASSWORD=app1 "$PG_IMAGE" >/dev/null
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Running}}' "$BAD")" = "false" ] && break
  sleep 1
done
if [ "$(docker inspect -f '{{.State.Running}}' "$BAD")" != "false" ]; then
  echo "FAIL: postgres kept running with an unsafe password" >&2
  exit 1
fi
docker logs "$BAD" 2>&1 | grep -q "must contain only letters and digits" \
  || { echo "FAIL: no password error in the log" >&2; exit 1; }
leftover="$(docker run --rm --entrypoint sh -v "$BAD_VOLUME:/data" "$PG_IMAGE" -c 'ls -A /data | wc -l')"
if [ "$leftover" != "0" ]; then
  echo "FAIL: the rejected start left $leftover entries in the data volume" >&2
  exit 1
fi
echo "ok"

echo "== maintenance refuses a missing token, a malformed interval and a zero timeout =="
if docker run --rm "$MAINT_IMAGE" >/dev/null 2>&1; then
  echo "FAIL: maintenance started without CLOUD_AGENTS_API_TOKEN" >&2
  exit 1
fi
if docker run --rm -e CLOUD_AGENTS_API_TOKEN=t -e MAINTENANCE_REAP_SECONDS=1m "$MAINT_IMAGE" >/dev/null 2>&1; then
  echo "FAIL: maintenance accepted MAINTENANCE_REAP_SECONDS=1m" >&2
  exit 1
fi
if docker run --rm -e CLOUD_AGENTS_API_TOKEN=t -e MAINTENANCE_REAP_TIMEOUT_SECONDS=0 "$MAINT_IMAGE" >/dev/null 2>&1; then
  echo "FAIL: maintenance accepted MAINTENANCE_REAP_TIMEOUT_SECONDS=0" >&2
  exit 1
fi
echo "ok"

echo "== maintenance stays up with every endpoint disabled =="
docker run -d --name "$IDLE" -e CLOUD_AGENTS_API_TOKEN=t -e MAINTENANCE_START_DELAY_SECONDS=0 \
  -e MAINTENANCE_REAP_SECONDS=0 -e MAINTENANCE_TRIGGER_JOBS_SECONDS=0 \
  -e MAINTENANCE_DRAIN_GRAPH_INGEST_SECONDS=0 -e MAINTENANCE_OBSERVE_SECONDS=0 \
  -e MAINTENANCE_LEDGER_SYNC_SECONDS=0 -e MAINTENANCE_MEMBERSHIP_SYNC_SECONDS=0 "$MAINT_IMAGE" >/dev/null
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' "$IDLE")" != "true" ]; then
  docker logs "$IDLE" >&2
  echo "FAIL: maintenance exited with every endpoint disabled" >&2
  exit 1
fi
echo "ok"
