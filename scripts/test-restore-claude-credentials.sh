#!/usr/bin/env bash
# Regression test for docker/restore-claude-credentials.sh: the newer of the
# vault login and the home-volume login wins. Runs the REAL function against
# temp files; no Docker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/docker/restore-claude-credentials.sh"
[ -f "$HELPER" ] || { echo "test-restore-claude-credentials: $HELPER not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test-restore-claude-credentials: jq required" >&2; exit 1; }

source "$HELPER"

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

not() { ! "$@"; }
login() { # access refresh expiresAt
  jq -cn --arg a "$1" --arg r "$2" --argjson e "$3" '{claudeAiOauth:{accessToken:$a,refreshToken:$r,expiresAt:$e}}'
}
access_of() { jq -r '.claudeAiOauth.accessToken' "$1"; }

D="$(mktemp -d)"
F="$D/.claude/.credentials.json"

# Fresh volume: the vault copy is restored, mode 600, only claudeAiOauth kept.
export CLAUDE_CREDENTIALS_JSON="$(jq -cn '{claudeAiOauth:{accessToken:"vault-a",refreshToken:"vault-r",expiresAt:1790000000000},mcpOAuth:{x:1}}')"
check "fresh volume restores" restore_claude_credentials "$F"
check "restored access token" test "$(access_of "$F")" = "vault-a"
check "extra keys dropped" test "$(jq 'keys|length' "$F")" = "1"
check "mode 600" test "$(stat -c '%a' "$F")" = "600"

# Volume holds a refreshed (later-expiring) login: the vault must not clobber it.
login "volume-a" "volume-r" 1790000999999 > "$F"
check "stale vault copy is not restored" not restore_claude_credentials "$F"
check "volume login untouched" test "$(access_of "$F")" = "volume-a"

# A freshly pasted login that expires later replaces the stale volume copy.
export CLAUDE_CREDENTIALS_JSON="$(login "pasted-a" "pasted-r" 1791000000000)"
check "newer vault copy wins" restore_claude_credentials "$F"
check "pasted access token restored" test "$(access_of "$F")" = "pasted-a"

# Equal expiry: leave the file alone.
login "same-a" "same-r" 1791000000000 > "$F"
restore_claude_credentials "$F" || true
check "equal expiry keeps file" test "$(access_of "$F")" = "same-a"

# Volume file without a usable access token is treated as absent.
echo '{"claudeAiOauth":{}}' > "$F"
check "unusable volume file replaced" restore_claude_credentials "$F"
check "replaced access token" test "$(access_of "$F")" = "pasted-a"

# Unusable vault input leaves everything alone.
login "keep-a" "keep-r" 1 > "$F"
export CLAUDE_CREDENTIALS_JSON='not json'
restore_claude_credentials "$F" || true
check "garbage vault value ignored" test "$(access_of "$F")" = "keep-a"
export CLAUDE_CREDENTIALS_JSON='{"claudeAiOauth":{"refreshToken":"r"}}'
restore_claude_credentials "$F" || true
check "vault value without access token ignored" test "$(access_of "$F")" = "keep-a"
unset CLAUDE_CREDENTIALS_JSON
check "unset vault value is a no-op" not restore_claude_credentials "$F"

rm -rf "$D"
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all checks passed"
