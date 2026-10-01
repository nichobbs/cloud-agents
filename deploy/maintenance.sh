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
#   MAINTENANCE_MEMBERSHIP_SYNC_SECONDS    default 300
#   MAINTENANCE_START_DELAY_SECONDS        default 15 (wait for the API on start)
# An interval of 0 disables that endpoint.
#
# Each endpoint also has a timeout, the longest one call may take before it
# is abandoned (at least 1 second), sized to the work that endpoint does:
#   MAINTENANCE_REAP_TIMEOUT_SECONDS               default 1800
#   MAINTENANCE_TRIGGER_JOBS_TIMEOUT_SECONDS       default 10800 (runs jobs inline, ~150 min worst case)
#   MAINTENANCE_DRAIN_GRAPH_INGEST_TIMEOUT_SECONDS default 1800
#   MAINTENANCE_OBSERVE_TIMEOUT_SECONDS            default 10800 (runs observer passes inline)
#   MAINTENANCE_LEDGER_SYNC_TIMEOUT_SECONDS        default 3600
#   MAINTENANCE_MEMBERSHIP_SYNC_TIMEOUT_SECONDS    default 1800
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
  timeout=$2
  # The timeout only stops a hung connection from stalling the loop for
  # good; the connect timeout catches an API that is down.
  if out=$(curl -sS --connect-timeout 10 --max-time "$timeout" -X POST \
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

check_timeout() {
  check_interval "$1" "$2"
  if [ "$2" -eq 0 ]; then
    echo "maintenance: $1 must be at least 1" >&2
    exit 1
  fi
}

loop() {
  path=$1
  seconds=$2
  timeout=$3
  if [ "$seconds" -eq 0 ]; then
    log "${path}: disabled"
    return 0
  fi
  log "${path}: every ${seconds}s, timeout ${timeout}s"
  while true; do
    call "$path" "$timeout"
    sleep "$seconds"
  done
}

REAP="${MAINTENANCE_REAP_SECONDS:-60}"
TRIGGER_JOBS="${MAINTENANCE_TRIGGER_JOBS_SECONDS:-60}"
DRAIN="${MAINTENANCE_DRAIN_GRAPH_INGEST_SECONDS:-60}"
OBSERVE="${MAINTENANCE_OBSERVE_SECONDS:-60}"
LEDGER_SYNC="${MAINTENANCE_LEDGER_SYNC_SECONDS:-300}"
MEMBERSHIP_SYNC="${MAINTENANCE_MEMBERSHIP_SYNC_SECONDS:-300}"
START_DELAY="${MAINTENANCE_START_DELAY_SECONDS:-15}"
REAP_TIMEOUT="${MAINTENANCE_REAP_TIMEOUT_SECONDS:-1800}"
TRIGGER_JOBS_TIMEOUT="${MAINTENANCE_TRIGGER_JOBS_TIMEOUT_SECONDS:-10800}"
DRAIN_TIMEOUT="${MAINTENANCE_DRAIN_GRAPH_INGEST_TIMEOUT_SECONDS:-1800}"
OBSERVE_TIMEOUT="${MAINTENANCE_OBSERVE_TIMEOUT_SECONDS:-10800}"
LEDGER_SYNC_TIMEOUT="${MAINTENANCE_LEDGER_SYNC_TIMEOUT_SECONDS:-3600}"
MEMBERSHIP_SYNC_TIMEOUT="${MAINTENANCE_MEMBERSHIP_SYNC_TIMEOUT_SECONDS:-1800}"
check_interval MAINTENANCE_REAP_SECONDS "$REAP"
check_interval MAINTENANCE_TRIGGER_JOBS_SECONDS "$TRIGGER_JOBS"
check_interval MAINTENANCE_DRAIN_GRAPH_INGEST_SECONDS "$DRAIN"
check_interval MAINTENANCE_OBSERVE_SECONDS "$OBSERVE"
check_interval MAINTENANCE_LEDGER_SYNC_SECONDS "$LEDGER_SYNC"
check_interval MAINTENANCE_MEMBERSHIP_SYNC_SECONDS "$MEMBERSHIP_SYNC"
check_interval MAINTENANCE_START_DELAY_SECONDS "$START_DELAY"
check_timeout MAINTENANCE_REAP_TIMEOUT_SECONDS "$REAP_TIMEOUT"
check_timeout MAINTENANCE_TRIGGER_JOBS_TIMEOUT_SECONDS "$TRIGGER_JOBS_TIMEOUT"
check_timeout MAINTENANCE_DRAIN_GRAPH_INGEST_TIMEOUT_SECONDS "$DRAIN_TIMEOUT"
check_timeout MAINTENANCE_OBSERVE_TIMEOUT_SECONDS "$OBSERVE_TIMEOUT"
check_timeout MAINTENANCE_LEDGER_SYNC_TIMEOUT_SECONDS "$LEDGER_SYNC_TIMEOUT"
check_timeout MAINTENANCE_MEMBERSHIP_SYNC_TIMEOUT_SECONDS "$MEMBERSHIP_SYNC_TIMEOUT"

# Give the API a moment to start listening on a fresh deploy.
sleep "$START_DELAY"

loop reap "$REAP" "$REAP_TIMEOUT" &
loop trigger-jobs "$TRIGGER_JOBS" "$TRIGGER_JOBS_TIMEOUT" &
loop drain-graph-ingest "$DRAIN" "$DRAIN_TIMEOUT" &
loop observe "$OBSERVE" "$OBSERVE_TIMEOUT" &
loop ledger-sync "$LEDGER_SYNC" "$LEDGER_SYNC_TIMEOUT" &
loop membership-sync "$MEMBERSHIP_SYNC" "$MEMBERSHIP_SYNC_TIMEOUT" &

# The enabled loops never return, so this blocks until the container stops.
wait
# Every endpoint is disabled: stay up rather than exit, so the restart
# policy does not restart the container over and over.
log "every endpoint is disabled; idling"
while true; do
  sleep 3600
done
