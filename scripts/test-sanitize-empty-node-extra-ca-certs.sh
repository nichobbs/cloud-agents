#!/usr/bin/env bash
# Regression test for docker/sanitize-empty-node-extra-ca-certs.sh
# (docs/BUILD.md's NODE_EXTRA_CA_CERTS incident). Sources the REAL script
# (the way every entrypoint variant actually uses it — see its own header
# comment for why it must be sourced, never executed) against real temp
# files covering missing/empty/non-empty NODE_EXTRA_CA_CERTS and the
# already-unset case. No Docker, no network.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/docker/sanitize-empty-node-extra-ca-certs.sh"
[ -f "$SCRIPT" ] || { echo "test-sanitize-empty-node-extra-ca-certs: $SCRIPT not found" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

# Each case sources the real script in its own subshell (bash -c), so one
# case's env mutation never leaks into the next, exactly mirroring how each
# entrypoint invocation is itself a single fresh process.
is_unset() {
  bash -c "NODE_EXTRA_CA_CERTS=\$1; source '$SCRIPT'; [ -z \"\${NODE_EXTRA_CA_CERTS+x}\" ]" _ "$1"
}
stays_set_to() {
  bash -c "NODE_EXTRA_CA_CERTS=\$1; source '$SCRIPT'; [ \"\${NODE_EXTRA_CA_CERTS:-}\" = \"\$2\" ]" _ "$1" "$2"
}

check "missing file: unsets NODE_EXTRA_CA_CERTS" \
  is_unset "$WORK/does-not-exist.pem"

: > "$WORK/empty.pem"
check "empty file: unsets NODE_EXTRA_CA_CERTS (the production bug — #1263)" \
  is_unset "$WORK/empty.pem"

check "literal empty string (no file at all): unsets NODE_EXTRA_CA_CERTS" \
  is_unset ""

echo "-----BEGIN CERTIFICATE-----" > "$WORK/real.pem"
echo "REALCERTDATA" >> "$WORK/real.pem"
echo "-----END CERTIFICATE-----" >> "$WORK/real.pem"
check "non-empty file: NODE_EXTRA_CA_CERTS stays set to the same path" \
  stays_set_to "$WORK/real.pem" "$WORK/real.pem"

# Already-unset case: NODE_EXTRA_CA_CERTS never set at all (not even to "").
check "already unset: stays unset" \
  bash -c "unset NODE_EXTRA_CA_CERTS; source '$SCRIPT'; [ -z \"\${NODE_EXTRA_CA_CERTS+x}\" ]"

if [ "$fails" -gt 0 ]; then
  echo "test-sanitize-empty-node-extra-ca-certs: $fails check(s) failed" >&2
  exit 1
fi
echo "test-sanitize-empty-node-extra-ca-certs: all checks passed"
