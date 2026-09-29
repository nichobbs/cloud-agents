#!/bin/bash
# Nightly backup of all persistent API state:
#   - the SQLite database (online, consistent snapshot via sqlite3 .backup,
#     safe while the api container is running and writing in WAL mode; a raw
#     file copy of a live WAL database can capture a torn state);
#   - artifact and chat-attachment bytes under CLOUD_AGENTS_DATA_DIR;
#   - the user credential volume (user_data, mounted at /user-home).
#
# Schedule via cron:
#   0 3 * * * /opt/cloud-agents/deploy/backup.sh >> /var/log/cloud-agents-backup.log 2>&1
#
# Overrides:
#   BACKUP_DIR             where archives land (default /opt/cloud-agents/backups)
#   CLOUD_AGENTS_DATA_DIR  host data directory (default /var/lib/cloud-agents,
#                          must match the value the compose file was deployed with)
#   USER_DATA_VOLUME       name of the user_data volume (default deploy_user_data;
#                          Coolify assigns its own project prefix, see COOLIFY.md)
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/cloud-agents/backups}"
DATA_DIR="${CLOUD_AGENTS_DATA_DIR:-/var/lib/cloud-agents}"
VOLUME="${USER_DATA_VOLUME:-deploy_user_data}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DB_FILE="cloud-agents.db"

mkdir -p "${BACKUP_DIR}"

# Fail loudly rather than archive nothing: a missing database means the data
# directory is wrong (or the api has never started), and a silently empty
# backup is worse than a failed cron job.
if [ ! -f "${DATA_DIR}/${DB_FILE}" ]; then
    echo "backup failed: ${DATA_DIR}/${DB_FILE} not found (check CLOUD_AGENTS_DATA_DIR)" >&2
    exit 1
fi
if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
    echo "backup failed: volume ${VOLUME} not found (check USER_DATA_VOLUME)" >&2
    exit 1
fi

# The data directory is mounted read-write: sqlite3 needs to open the -shm
# file of a WAL database even to read it.
docker run --rm \
    -v "${DATA_DIR}:/data" \
    -v "${BACKUP_DIR}:/backup" \
    alpine \
    sh -c "apk add --no-cache sqlite >/dev/null \
        && sqlite3 /data/${DB_FILE} \".backup /backup/db-${STAMP}.db\" \
        && sqlite3 /backup/db-${STAMP}.db 'PRAGMA integrity_check' | grep -qx ok \
        && gzip /backup/db-${STAMP}.db"

docker run --rm \
    -v "${DATA_DIR}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine \
    tar czf "/backup/files-${STAMP}.tar.gz" -C /data \
        --exclude="./${DB_FILE}" --exclude="./${DB_FILE}-*" .

docker run --rm \
    -v "${VOLUME}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine \
    tar czf "/backup/user-home-${STAMP}.tar.gz" -C /data .

# Retain the 14 most recent archives of each kind.
for prefix in db files user-home; do
    ls -1t "${BACKUP_DIR}/${prefix}-"* 2>/dev/null | tail -n +15 | xargs -r rm -f
done

echo "backup complete: ${BACKUP_DIR}/{db,files,user-home}-${STAMP}.*"
