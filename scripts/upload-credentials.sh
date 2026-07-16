#!/usr/bin/env bash
# Auto-detect harness credentials on this machine and upload them to the
# Cloud Agents credential vault, so runner containers can authenticate.
#
# Detects (skipping anything not present):
#   Claude Code : CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY env vars,
#                 ~/.claude/.credentials.json (OAuth access token)
#   Codex CLI   : OPENAI_API_KEY env var, ~/.codex/auth.json
#   OpenCode    : ~/.local/share/opencode/auth.json (per-provider API keys)
#   Gemini CLI  : GEMINI_API_KEY / GOOGLE_API_KEY env vars
#   GitHub      : GITHUB_TOKEN env var, `gh auth token`
#
# Usage:
#   CLOUD_AGENTS_URL=http://localhost:8080 \
#   CLOUD_AGENTS_API_TOKEN=... \
#   ./scripts/upload-credentials.sh [--dry-run]
#
# The API token is required whenever the server has CLOUD_AGENTS_API_TOKEN
# configured (credential routes always require it there). Values are sent
# only to your own Cloud Agents server, over the URL you provide.

set -euo pipefail

BASE_URL="${CLOUD_AGENTS_URL:-http://localhost:8080}"
API_TOKEN="${CLOUD_AGENTS_API_TOKEN:-}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

command -v curl >/dev/null || { echo "upload-credentials: 'curl' not on PATH" >&2; exit 1; }

json_extract() {
    # json_extract <file> <python-expression over parsed `d`>
    python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = eval(sys.argv[2], {"d": d})
    if isinstance(v, str) and v:
        print(v)
except Exception:
    pass
PY
}

uploaded=0
failed=0

upload() {
    local name="$1" value="$2" source="$3"
    [ -n "$value" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        echo "would upload ${name}  (${source})"
        return 0
    fi
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "value": sys.argv[2]}))' "$name" "$value")
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/api/credentials" \
        -H 'Content-Type: application/json' \
        ${API_TOKEN:+-H "Authorization: Bearer ${API_TOKEN}"} \
        --data "$payload") || code=000
    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        echo "uploaded ${name}  (${source})"
        uploaded=$((uploaded + 1))
    else
        echo "FAILED  ${name}  (${source}) — HTTP ${code}" >&2
        failed=$((failed + 1))
    fi
}

# ── Claude Code ────────────────────────────────────────────────────────────────
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    upload CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN" "env"
elif [ -f "$HOME/.claude/.credentials.json" ]; then
    token=$(json_extract "$HOME/.claude/.credentials.json" 'd["claudeAiOauth"]["accessToken"]')
    upload CLAUDE_CODE_OAUTH_TOKEN "$token" "~/.claude/.credentials.json"
fi
[ -n "${ANTHROPIC_API_KEY:-}" ] && upload ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY" "env"

# ── Codex CLI ─────────────────────────────────────────────────────────────────
if [ -n "${OPENAI_API_KEY:-}" ]; then
    upload OPENAI_API_KEY "$OPENAI_API_KEY" "env"
elif [ -f "$HOME/.codex/auth.json" ]; then
    key=$(json_extract "$HOME/.codex/auth.json" 'd["OPENAI_API_KEY"]')
    upload OPENAI_API_KEY "$key" "~/.codex/auth.json"
fi

# ── OpenCode ──────────────────────────────────────────────────────────────────
opencode_auth="$HOME/.local/share/opencode/auth.json"
if [ -f "$opencode_auth" ]; then
    for pair in "anthropic:ANTHROPIC_API_KEY" "openai:OPENAI_API_KEY" "google:GEMINI_API_KEY"; do
        provider="${pair%%:*}"
        env_name="${pair##*:}"
        key=$(json_extract "$opencode_auth" "d[\"$provider\"][\"key\"] if d.get(\"$provider\", {}).get(\"type\") == \"api\" else \"\"")
        upload "$env_name" "$key" "opencode auth.json ($provider)"
    done
fi

# ── Gemini CLI ────────────────────────────────────────────────────────────────
if [ -n "${GEMINI_API_KEY:-}" ]; then
    upload GEMINI_API_KEY "$GEMINI_API_KEY" "env"
elif [ -n "${GOOGLE_API_KEY:-}" ]; then
    upload GEMINI_API_KEY "$GOOGLE_API_KEY" "env (GOOGLE_API_KEY)"
fi

# ── GitHub ────────────────────────────────────────────────────────────────────
if [ -n "${GITHUB_TOKEN:-}" ]; then
    upload GITHUB_TOKEN "$GITHUB_TOKEN" "env"
elif command -v gh >/dev/null 2>&1; then
    token=$(gh auth token 2>/dev/null || true)
    upload GITHUB_TOKEN "$token" "gh auth token"
fi

echo
if [ "$DRY_RUN" = "1" ]; then
    echo "dry run complete — nothing uploaded"
elif [ "$uploaded" = "0" ] && [ "$failed" = "0" ]; then
    echo "no credentials detected on this machine"
else
    echo "done: ${uploaded} uploaded, ${failed} failed"
fi
[ "$failed" = "0" ]
