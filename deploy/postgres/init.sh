#!/bin/sh
# Runs once, on the postgres container's first start (an empty data volume),
# from /docker-entrypoint-initdb.d. Provisions the cloud-agents database and
# roles from provision.sql (docs/phase11-postgres-tenancy.md §8). Later starts
# skip it, so changing a password in the environment afterwards needs an
# ALTER ROLE by hand (deploy/RUNBOOK.md).
set -eu

check_password() {
  # The passwords are interpolated into SQL and into DSNs, so they are
  # restricted to characters that need no quoting in either. entrypoint.sh
  # already checked them before the data directory existed; this repeats the
  # check next to the interpolation it protects.
  name=$1
  value=$2
  if [ -z "$value" ]; then
    echo "init.sh: $name is not set" >&2
    exit 1
  fi
  case "$value" in
    *[!A-Za-z0-9]*)
      echo "init.sh: $name must contain only letters and digits (use: openssl rand -hex 24)" >&2
      exit 1
      ;;
  esac
}

check_password CLOUD_AGENTS_PG_OWNER_PASSWORD "${CLOUD_AGENTS_PG_OWNER_PASSWORD:-}"
check_password CLOUD_AGENTS_PG_APP_PASSWORD "${CLOUD_AGENTS_PG_APP_PASSWORD:-}"

# cloudagents_migrator is created NOLOGIN; its password is never used, so a
# random one is generated here rather than asked for.
migrator_password=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner_password="'$CLOUD_AGENTS_PG_OWNER_PASSWORD'" \
  -v app_password="'$CLOUD_AGENTS_PG_APP_PASSWORD'" \
  -v migrator_password="'$migrator_password'" \
  -f /opt/cloud-agents/provision.sql
