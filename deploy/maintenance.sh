#!/bin/sh
# The maintenance poller: calls the API's operator-only maintenance endpoints
# on a schedule, because the server has no in-process timer
# (docs/phase8-scheduling.md §2, docs/phase11-postgres-tenancy.md §5.3a).
#
# Each endpoint has its own loop, so a long call (trigger-jobs runs due jobs
# inline and can take a long time) never delays the others. A loop waits for
# its call to finish before sleeping, so one endpoint's calls never overlap
# here; overlap with another poller is safe too, because every sweep claims
# its work first.
#
# Environment:
#   CLOUD_AGENTS_API_TOKEN     required; the operator bearer token.
#   CLOUD_AGENTS_API_URL       default http://api:8080
#   MAINTENANCE_REAP_SECONDS               default 60
#   MAINTENANCE_TRIGGER_JOBS_SECONDS       default 60
#   MAINTENANCE_DRAIN_GRAPH_INGEST_SECONDS default 60
#   MAINTENANCE_OBSERVE_SECONDS            default 60
#   MAINTENANCE_LEDGER_SYNC_SECONDS        default 300
#   MAINTENANCE_START_DELAY_SECONDS        default 15 (wait for the API on start)
# An interval of 0 disables that endpoint.
set -eu

if [ -z "${CLOUD_AGENTS_API_TOKEN:-}" ]; then
  echo "maintenance: CLOUD_AGENTS_API_TOKEN is not set; the maintenance endpoints only run for the operator" >&2
  exit 1
fi
API_URL="${CLOUD_AGENTS_API_URL:-http://api:8080}"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

call() {
  path=$1
  # No overall time limit: trigger-jobs and observe run their work inline.
  # The connect timeout catches an API that is down.
  if out=$(curl -sS --connect-timeout 10 -X POST \
    -H "Authorization: Bearer ${CLOUD_AGENTS_API_TOKEN}" \
    -w ' [HTTP %{http_code}]' \
    "${API_URL}/api/maintenance/${path}" 2>&1); then
    log "${path}: ${out}"
  else
    log "${path}: request failed: ${out}"
  fi
}

check_interval() {
  case "$2" in
    ''|*[!0-9]*)
      echo "maintenance: $1 must be a whole number of seconds, got '$2'" >&2
      exit 1
      ;;
  esac
}

loop() {
  path=$1
  seconds=$2
  if [ "$seconds" -eq 0 ]; then
    log "${path}: disabled"
    return 0
  fi
  log "${path}: every ${seconds}s"
  while true; do
    call "$path"
    sleep "$seconds"
  done
}

REAP="${MAINTENANCE_REAP_SECONDS:-60}"
TRIGGER_JOBS="${MAINTENANCE_TRIGGER_JOBS_SECONDS:-60}"
DRAIN="${MAINTENANCE_DRAIN_GRAPH_INGEST_SECONDS:-60}"
OBSERVE="${MAINTENANCE_OBSERVE_SECONDS:-60}"
LEDGER_SYNC="${MAINTENANCE_LEDGER_SYNC_SECONDS:-300}"
START_DELAY="${MAINTENANCE_START_DELAY_SECONDS:-15}"
check_interval MAINTENANCE_REAP_SECONDS "$REAP"
check_interval MAINTENANCE_TRIGGER_JOBS_SECONDS "$TRIGGER_JOBS"
check_interval MAINTENANCE_DRAIN_GRAPH_INGEST_SECONDS "$DRAIN"
check_interval MAINTENANCE_OBSERVE_SECONDS "$OBSERVE"
check_interval MAINTENANCE_LEDGER_SYNC_SECONDS "$LEDGER_SYNC"
check_interval MAINTENANCE_START_DELAY_SECONDS "$START_DELAY"

# Give the API a moment to start listening on a fresh deploy.
sleep "$START_DELAY"

loop reap "$REAP" &
loop trigger-jobs "$TRIGGER_JOBS" &
loop drain-graph-ingest "$DRAIN" &
loop observe "$OBSERVE" &
loop ledger-sync "$LEDGER_SYNC" &

# The enabled loops never return, so this blocks until the container stops.
wait
