#!/usr/bin/env bash
# Regression test for the entrypoint's "claude-login" inspect mode (the helper
# container that reads a refreshed Claude login back for the vault write-back,
# docker_manager.l writeBackClaudeLogin). Runs the REAL entrypoint block against
# a temp home; no Docker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint.sh"
command -v jq >/dev/null 2>&1 || { echo "test-claude-login-readback: jq required" >&2; exit 1; }

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

H="$(mktemp -d)"
mkdir -p "$H/.claude"
F="$H/.claude/.credentials.json"
run() { CLOUD_AGENTS_INSPECT_MODE=claude-login CLOUD_AGENTS_LOGIN_HOME="$H" bash "$ENTRYPOINT"; }

echo '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":5,"scopes":["x"]},"mcpOAuth":{"secret":"must-not-leak"}}' > "$F"
out="$(run)"
check "OK marker first" test "$(printf '%s\n' "$out" | sed -n 1p)" = "CLOUD_AGENTS_INSPECT_OK"
check "prints the claudeAiOauth object" test "$(printf '%s\n' "$out" | sed -n 2p | jq -r '.claudeAiOauth.accessToken')" = "a"
check "keeps the refresh token" test "$(printf '%s\n' "$out" | sed -n 2p | jq -r '.claudeAiOauth.refreshToken')" = "r"
check "never prints other keys" bash -c '! printf "%s" "$1" | grep -q must-not-leak' _ "$out"

echo '{"claudeAiOauth":{}}' > "$F"
check "no access token is an error" test "$(run)" = "CLOUD_AGENTS_INSPECT_ERR no login"
echo 'not json' > "$F"
check "garbage is an error" test "$(run)" = "CLOUD_AGENTS_INSPECT_ERR no login"
rm -f "$F"
check "missing file is an error" test "$(run)" = "CLOUD_AGENTS_INSPECT_ERR no login"

rm -rf "$H"
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all checks passed"
