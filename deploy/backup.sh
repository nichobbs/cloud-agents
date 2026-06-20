#!/bin/bash
# Phase 5 — nightly backup of the user credential volume.
#
# Schedule via cron:
#   0 3 * * * /opt/cloud-agents/deploy/backup.sh >> /var/log/cloud-agents-backup.log 2>&1
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/cloud-agents/backups}"
VOLUME="${USER_DATA_VOLUME:-deploy_user_data}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "${BACKUP_DIR}"

docker run --rm \
    -v "${VOLUME}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine \
    tar czf "/backup/user-home-${STAMP}.tar.gz" -C /data .

# Retain the 14 most recent archives.
ls -1t "${BACKUP_DIR}"/user-home-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f

echo "backup complete: ${BACKUP_DIR}/user-home-${STAMP}.tar.gz"
