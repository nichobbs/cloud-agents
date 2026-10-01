#!/bin/sh
# Checks the role passwords before handing over to the stock entrypoint.
# The stock entrypoint creates the data directory before it runs the init
# scripts, so a password rejected only by init.sh would leave a volume that
# every later start treats as already provisioned (no cloudagents database,
# no roles). Rejecting it here, first, leaves the volume empty, and fixing
# the variable is enough to recover.
set -eu

check_password() {
  name=$1
  value=$2
  if [ -z "$value" ]; then
    echo "postgres: $name is not set" >&2
    exit 1
  fi
  case "$value" in
    *[!A-Za-z0-9]*)
      echo "postgres: $name must contain only letters and digits (use: openssl rand -hex 24)" >&2
      exit 1
      ;;
  esac
}

check_password CLOUD_AGENTS_PG_OWNER_PASSWORD "${CLOUD_AGENTS_PG_OWNER_PASSWORD:-}"
check_password CLOUD_AGENTS_PG_APP_PASSWORD "${CLOUD_AGENTS_PG_APP_PASSWORD:-}"

exec docker-entrypoint.sh "$@"
