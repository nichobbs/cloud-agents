#!/usr/bin/env bash
# Regression test for docker/register-callbacks-mcp.sh (the cloud-agents MCP
# shim registration for the non-claude harnesses). Exercises the REAL
# function against temp workspaces, faking the shim binary on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/docker/register-callbacks-mcp.sh"
[ -f "$HELPER" ] || { echo "test-register-callbacks-mcp: $HELPER not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test-register-callbacks-mcp: jq required" >&2; exit 1; }

source "$HELPER"

# Fake cloud-agents-shim on PATH so callbacks_mcp_active's binary check passes.
BINDIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "$BINDIR/cloud-agents-shim"
chmod +x "$BINDIR/cloud-agents-shim"
export PATH="$BINDIR:$PATH"

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

live_env() {
  export CLOUD_AGENTS_MCP_CALLBACKS=1
  export CLOUD_AGENTS_CALLBACK_TOKEN="tok-with-\"quote\"-and-\\backslash"
  export CLOUD_AGENTS_API_URL="http://host:8080"
  export SESSION_ID="sess-1"
  export CLOUD_AGENTS_CALLBACK_TIMEOUT_MS="1234"
}

dead_env() {
  export CLOUD_AGENTS_MCP_CALLBACKS=1
  export CLOUD_AGENTS_CALLBACK_TOKEN=""
}

# ── OpenCode: adds .mcp["cloud-agents"], strips it when inactive ─────────────
WS="$(mktemp -d)"
printf '{"mcp":{"cloud-agents-lib-x":{"command":"y"}},"instructions":["AGENTS.md"]}' > "$WS/opencode.json"
live_env
register_callbacks_mcp "opencode" "$WS"
check "opencode: entry added"                 bash -c "jq -e '.mcp[\"cloud-agents\"].type == \"local\"' '$WS/opencode.json' >/dev/null"
check "opencode: command is the shim"         bash -c "jq -e '.mcp[\"cloud-agents\"].command == [\"cloud-agents-shim\"]' '$WS/opencode.json' >/dev/null"
check "opencode: token survives JSON metachars" bash -c "jq -e '.mcp[\"cloud-agents\"].environment.CLOUD_AGENTS_CALLBACK_TOKEN | contains(\"quote\")' '$WS/opencode.json' >/dev/null"
check "opencode: unrelated entries intact"    bash -c "jq -e '.mcp[\"cloud-agents-lib-x\"]' '$WS/opencode.json' >/dev/null"
check "opencode: valid JSON after add"        bash -c "jq -e . '$WS/opencode.json' >/dev/null"
dead_env
register_callbacks_mcp "opencode" "$WS"
check "opencode: entry stripped when inactive" bash -c "! jq -e '.mcp[\"cloud-agents\"]' '$WS/opencode.json' >/dev/null"
check "opencode: unrelated entries survive strip" bash -c "jq -e '.mcp[\"cloud-agents-lib-x\"]' '$WS/opencode.json' >/dev/null"
rm -rf "$WS"

# ── Gemini: adds .mcpServers["cloud-agents"] in .gemini/settings.json ────────
WS="$(mktemp -d)"
live_env
register_callbacks_mcp "gemini" "$WS"
check "gemini: settings.json created"         test -f "$WS/.gemini/settings.json"
check "gemini: entry added"                   bash -c "jq -e '.mcpServers[\"cloud-agents\"].command == \"cloud-agents-shim\"' '$WS/.gemini/settings.json' >/dev/null"
dead_env
register_callbacks_mcp "gemini" "$WS"
check "gemini: entry stripped when inactive"  bash -c "! jq -e '.mcpServers[\"cloud-agents\"]' '$WS/.gemini/settings.json' >/dev/null"
rm -rf "$WS"

# ── Codex: marker-delimited TOML block, idempotent, strip on inactive ────────
WS="$(mktemp -d)"
mkdir -p "$WS/.codex"
printf '%s\n' "model = \"user-set\"" > "$WS/.codex/config.toml"
live_env
register_callbacks_mcp "codex" "$WS"
check "codex: block added"                    grep -q '\[mcp_servers.cloud-agents\]' "$WS/.codex/config.toml"
check "codex: user content intact"            grep -q 'model = "user-set"' "$WS/.codex/config.toml"
register_callbacks_mcp "codex" "$WS"
check "codex: second render is idempotent"    bash -c "[ \"\$(grep -c 'BEGIN cloud-agents-callbacks-mcp' '$WS/.codex/config.toml')\" -eq 1 ]"
dead_env
register_callbacks_mcp "codex" "$WS"
check "codex: block stripped when inactive"   bash -c "! grep -q 'mcp_servers.cloud-agents' '$WS/.codex/config.toml'"
check "codex: user content survives strip"    grep -q 'model = "user-set"' "$WS/.codex/config.toml"
rm -rf "$WS"

# ── Codex TOML parse validity (#789) ─────────────────────────────────────────
# The opencode/gemini branches are jq-validated above; parse the codex
# branch's TOML output with a real TOML parser too, and confirm a token full
# of quote/backslash metacharacters round-trips — @json escaping is shared
# between JSON and TOML basic strings, but only an actual parse proves it.
WS="$(mktemp -d)"
mkdir -p "$WS/.codex"
live_env
register_callbacks_mcp "codex" "$WS"
if python3 -c 'import tomllib' >/dev/null 2>&1; then
  toml_ok=0
  python3 -c '
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
env = cfg["mcp_servers"]["cloud-agents"]["env"]
expected = "tok-with-\"quote\"-and-\\backslash"
sys.exit(0 if env["CLOUD_AGENTS_CALLBACK_TOKEN"] == expected else 1)
' "$WS/.codex/config.toml" || toml_ok=1
  check "codex: config.toml parses as TOML and the metachar token round-trips" test "$toml_ok" -eq 0
else
  echo "skip codex TOML parse check (python3 tomllib unavailable)"
fi
rm -rf "$WS"

# ── .git/info/exclude protection (#788) ──────────────────────────────────────
WS="$(mktemp -d)"
mkdir -p "$WS/.git/info"
live_env
register_callbacks_mcp "opencode" "$WS"
register_callbacks_mcp "opencode" "$WS"
check "exclude: opencode.json listed once (idempotent)" bash -c "[ \"\$(grep -cxF '/opencode.json' '$WS/.git/info/exclude')\" -eq 1 ]"
register_callbacks_mcp "gemini" "$WS"
check "exclude: gemini settings listed"       bash -c "grep -qxF '/.gemini/settings.json' '$WS/.git/info/exclude'"
register_callbacks_mcp "codex" "$WS"
check "exclude: codex config listed"          bash -c "grep -qxF '/.codex/config.toml' '$WS/.git/info/exclude'"
rm -rf "$WS"

# No .git directory — exclusion is a silent no-op, registration still works.
WS="$(mktemp -d)"
live_env
register_callbacks_mcp "opencode" "$WS"
check "exclude: no .git -> no-op, entry still written" bash -c "jq -e '.mcp[\"cloud-agents\"]' '$WS/opencode.json' >/dev/null"
check "exclude: no .git dir was created"      bash -c "[ ! -d '$WS/.git' ]"
rm -rf "$WS"

# ── Git-tracked target file: never write the token into it (#799) ────────────
if command -v git >/dev/null 2>&1; then
  WS="$(mktemp -d)"
  git -C "$WS" init -q
  printf '{"instructions":["AGENTS.md"]}' > "$WS/opencode.json"
  git -C "$WS" add opencode.json
  git -C "$WS" -c user.email=t@t -c user.name=t commit -qm "track opencode.json"
  live_env
  register_callbacks_mcp "opencode" "$WS"
  check "tracked: no token written into a git-tracked opencode.json" \
    bash -c "! grep -q 'CLOUD_AGENTS_CALLBACK_TOKEN' '$WS/opencode.json'"
  check "tracked: no cloud-agents entry either" \
    bash -c "! jq -e '.mcp[\"cloud-agents\"]' '$WS/opencode.json' >/dev/null 2>&1"
  check "tracked: user content intact" \
    bash -c "jq -e '.instructions[0] == \"AGENTS.md\"' '$WS/opencode.json' >/dev/null"
  # An UNTRACKED gemini settings file in the same repo still registers.
  register_callbacks_mcp "gemini" "$WS"
  check "tracked: untracked sibling config still registers" \
    bash -c "jq -e '.mcpServers[\"cloud-agents\"]' '$WS/.gemini/settings.json' >/dev/null"
  rm -rf "$WS"
else
  echo "skip git-tracked checks (git unavailable)"
fi

# ── No temp-file litter after normal runs (#802) ─────────────────────────────
WS="$(mktemp -d)"
live_env
register_callbacks_mcp "opencode" "$WS"
dead_env
register_callbacks_mcp "opencode" "$WS"
check "no opencode.json.XXXXXX temp litter" \
  bash -c "[ -z \"\$(ls '$WS' | grep 'opencode.json\\.')\" ]"
rm -rf "$WS"

# ── Flag off ("0") suppresses registration even with a token ─────────────────
WS="$(mktemp -d)"
live_env
export CLOUD_AGENTS_MCP_CALLBACKS=0
register_callbacks_mcp "opencode" "$WS"
check "flag=0: no entry written"              bash -c "! jq -e '.mcp[\"cloud-agents\"]' '$WS/opencode.json' >/dev/null 2>&1"
rm -rf "$WS"

rm -rf "$BINDIR"
if [ "$fails" -ne 0 ]; then
  echo "==> test-register-callbacks-mcp: ${fails} check(s) failed" >&2
  exit 1
fi
echo "==> test-register-callbacks-mcp: all checks passed"
