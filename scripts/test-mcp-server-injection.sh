#!/usr/bin/env bash
# Regression test for docker/inject-library.sh's MCP-server rendering,
# specifically the env-value ${VAR} expansion added alongside the
# CloudAgents.McpServerSeed enabled/disabled feature: a seeded or
# user-authored server can write env=["GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}"]
# and get the real credential value CloudAgents.Docker already injected as a
# container env var, without that secret ever being stored in mcp_server_env
# (see docker/inject-library.sh's expand_env_value doc comment).
#
# Extracts the three functions under test (expand_env_value, render_mcp_json,
# render_mcp_codex) out of the real file rather than sourcing the whole
# script — inject-library.sh's own body ends in an unconditional
# `case $HARNESS in ... esac` that renders a full workspace as a side
# effect when sourced/executed, which a function-level unit test should not
# trigger.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/docker/inject-library.sh"
[ -f "$HELPER" ] || { echo "test-mcp-server-injection: $HELPER not found" >&2; exit 1; }

# Tracks brace depth rather than stopping at the first bare "}" line (#774):
# a bare "}" only ends the function when it closes back out to depth 0, so a
# future multi-line jq/awk block or heredoc inside one of these functions
# that happens to put a standalone "}" on its own line (a nested block, not
# the function's own close) won't truncate the extraction early. Depth is
# counted with gsub's match-count return rather than modifying $0, so the
# printed body is untouched; this assumes brace characters inside any
# embedded string/jq literal are themselves balanced within the function
# (true today — see docker/inject-library.sh's jq object-literal snippets).
extract_func() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ "^" name "\\(\\)" {found=1; depth=0}
    found {
      print
      depth += gsub(/\{/, "{")
      depth -= gsub(/\}/, "}")
      if (depth == 0) exit
    }
  ' "$HELPER"
}

FUNCS_FILE="$(mktemp)"
trap 'rm -f "$FUNCS_FILE"' EXIT
{
  extract_func "expand_env_value"
  extract_func "render_mcp_json"
  extract_func "render_mcp_codex"
} > "$FUNCS_FILE"

for fn in expand_env_value render_mcp_json render_mcp_codex; do
  grep -q "^${fn}()" "$FUNCS_FILE" || { echo "test-mcp-server-injection: failed to extract $fn from $HELPER" >&2; exit 1; }
done

source "$FUNCS_FILE"

fails=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "test-mcp-server-injection: jq not found, cannot run" >&2; exit 1; }

HAVE_ENVSUBST=1
command -v envsubst >/dev/null 2>&1 || HAVE_ENVSUBST=0

b64() { base64 -w0 2>/dev/null || base64; }

# ── Claude (JSON): env value with a credential reference expands when
# envsubst is present, and the pre-existing user entry survives while a
# stale cloud-agents-lib- entry is replaced ────────────────────────────────
WS="$(mktemp -d)"
(
  cd "$WS"
  export GITHUB_TOKEN="test-token-value"
  mkdir -p .claude
  cat > .claude/mcp.json <<'EOF'
{"mcpServers":{"my-own-server":{"command":"foo"},"cloud-agents-lib-stale":{"command":"old"}}}
EOF
  export CLOUD_AGENTS_MCP_SERVERS_B64=$(printf '%s' '{"mcpServers":[
    {"name":"github","transport":"stdio","command":"npx","args":["-y","server-github"],"url":"","env":["GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}"]},
    {"name":"fetch","transport":"stdio","command":"uvx","args":["mcp-server-fetch"],"url":"","env":[]},
    {"name":"remote","transport":"url","command":"","args":[],"url":"https://example.com/mcp","env":[]}
  ]}' | b64)

  render_mcp_json ".claude/mcp.json" '{"mcpServers":{}}' "mcpServers"
  jq -c . .claude/mcp.json > result.json
)

check "user's own entry survives"           jq -e ".mcpServers[\"my-own-server\"].command == \"foo\"" "$WS/result.json"
check "stale cloud-agents-lib- entry gone"  bash -c "! jq -e '.mcpServers | has(\"cloud-agents-lib-stale\")' '$WS/result.json' | grep -q true"
check "github entry rendered"               jq -e '.mcpServers["cloud-agents-lib-github"] != null' "$WS/result.json"
check "fetch entry has empty env object"    jq -e '.mcpServers["cloud-agents-lib-fetch"].env == {}' "$WS/result.json"
check "url-transport entry rendered"        jq -e '.mcpServers["cloud-agents-lib-remote"].url == "https://example.com/mcp"' "$WS/result.json"

if [ "$HAVE_ENVSUBST" -eq 1 ]; then
  check "credential reference expanded to the real value" \
    jq -e '.mcpServers["cloud-agents-lib-github"].env.GITHUB_PERSONAL_ACCESS_TOKEN == "test-token-value"' "$WS/result.json"
else
  check "no envsubst installed: value left literal, not silently dropped" \
    jq -e '.mcpServers["cloud-agents-lib-github"].env.GITHUB_PERSONAL_ACCESS_TOKEN == "${GITHUB_TOKEN}"' "$WS/result.json"
fi
rm -rf "$WS"

# ── expand_env_value's deny-list (#773): a literal "$HOME"/"$PROMPT"-shaped
# token in a value must NOT be silently rewritten, even though HOME and
# PROMPT are real vars in this process's environment — only an actual
# credential-style name (not in the deny-list) is a substitution target ──
if [ "$HAVE_ENVSUBST" -eq 1 ]; then
  WS2="$(mktemp -d)"
  (
    cd "$WS2"
    export HOME="/should/not/leak"
    export PROMPT="the entire user prompt, not meant to be substitutable"
    export GITHUB_TOKEN="real-cred-value"
    export CLOUD_AGENTS_MCP_SERVERS_B64=$(printf '%s' '{"mcpServers":[
      {"name":"literal-dollar","transport":"stdio","command":"npx","args":[],"url":"","env":["A=cost-is-$HOME-dollars","B=${PROMPT}","C=${GITHUB_TOKEN}"]}
    ]}' | b64)
    render_mcp_json ".claude/mcp.json" '{"mcpServers":{}}' "mcpServers"
    jq -c . .claude/mcp.json > result.json
  )
  check "deny-listed \$HOME left literal, not substituted" \
    jq -e '.mcpServers["cloud-agents-lib-literal-dollar"].env.A == "cost-is-$HOME-dollars"' "$WS2/result.json"
  check "deny-listed \${PROMPT} left literal, not substituted" \
    jq -e '.mcpServers["cloud-agents-lib-literal-dollar"].env.B == "${PROMPT}"' "$WS2/result.json"
  check "non-deny-listed credential ref still expands" \
    jq -e '.mcpServers["cloud-agents-lib-literal-dollar"].env.C == "real-cred-value"' "$WS2/result.json"
  rm -rf "$WS2"
fi

# ── Claude (JSON): an env value containing a literal embedded newline must
# not corrupt sibling entries — the env-pairs loop reads .env[] NUL-
# delimited, not newline-delimited, specifically so this can't happen ──────
WS="$(mktemp -d)"
(
  cd "$WS"
  export CLOUD_AGENTS_MCP_SERVERS_B64=$(printf '%s' '{"mcpServers":[
    {"name":"multiline","transport":"stdio","command":"foo","args":[],"url":"","env":["A=line1\nline2","B=second"]}
  ]}' | b64)

  render_mcp_json ".claude/mcp.json" '{"mcpServers":{}}' "mcpServers"
  jq -c . .claude/mcp.json > result.json
)
check "embedded-newline env value preserved whole, not truncated" \
  jq -e '.mcpServers["cloud-agents-lib-multiline"].env.A == "line1\nline2"' "$WS/result.json"
check "sibling env entry after a newline-containing value is unaffected" \
  jq -e '.mcpServers["cloud-agents-lib-multiline"].env.B == "second"' "$WS/result.json"
check "no spurious extra env key from a split newline" \
  jq -e '(.mcpServers["cloud-agents-lib-multiline"].env | keys | length) == 2' "$WS/result.json"
rm -rf "$WS"

# ── Codex (TOML): same expansion behavior, marker-delimited block ──────────
WS="$(mktemp -d)"
(
  cd "$WS"
  export GITHUB_TOKEN="test-token-value"
  export CLOUD_AGENTS_MCP_SERVERS_B64=$(printf '%s' '{"mcpServers":[{"name":"github","transport":"stdio","command":"npx","args":["-y","srv"],"url":"","env":["GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}"]}]}' | b64)
  render_mcp_codex
)
check "codex TOML block written"      test -f "$WS/.codex/config.toml"
check "codex server section present"  grep -q '\[mcp_servers.cloud-agents-lib-github\]' "$WS/.codex/config.toml"
if [ "$HAVE_ENVSUBST" -eq 1 ]; then
  check "codex env value expanded"  grep -q 'test-token-value' "$WS/.codex/config.toml"
else
  check "codex env value left literal without envsubst"  grep -qF '${GITHUB_TOKEN}' "$WS/.codex/config.toml"
fi
rm -rf "$WS"

if [ "$fails" -gt 0 ]; then
  echo "==> test-mcp-server-injection: ${fails} check(s) failed" >&2
  exit 1
fi
echo "==> test-mcp-server-injection: all checks passed"
