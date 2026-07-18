#!/bin/bash
# Runner entrypoint for a single Claude Code invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - Claude model to use (default: claude-opus-4-8)
#   NATIVE_SESSION_ID - session ID to resume; if non-empty passed to --resume
#   GITHUB_TOKEN      - PAT injected into the GitHub MCP server (Phase 4, optional)
#   CLOUD_AGENTS_MCP_CALLBACKS  - "1" to enable the Phase 6 MCP-callback shim
#                                 (docs/phase6-mcp-callbacks.md); default off.
#                                 Only takes effect once cloud-agents-shim
#                                 actually ships in this image (stage 3).
#   CLOUD_AGENTS_API_URL        - host API base URL, as reachable from this
#                                 container (only used when the flag above is
#                                 set; minted by CloudAgents.Docker)
#   CLOUD_AGENTS_CALLBACK_TOKEN - per-session callback bearer token (ditto)
#
# State persists across runs via two mounted volumes:
#   /workspace            - the cloned repository + .claude session files
#   /home/claude-user     - the user's authenticated ~/.claude credentials
#
# Each container handles exactly one prompt and then exits; --resume reads the
# conversation history from the workspace so context survives.

set -euo pipefail

BRANCH="${BRANCH:-main}"
MODEL="${MODEL:-claude-opus-4-8}"
NATIVE_SESSION_ID="${NATIVE_SESSION_ID:-}"
CLOUD_AGENTS_MCP_CALLBACKS="${CLOUD_AGENTS_MCP_CALLBACKS:-0}"

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint: PROMPT is required" >&2
    exit 64
fi

# Restore a Claude subscription (OAuth) login from the vault on a fresh home
# volume. A subscription login is a ~/.claude directory, not an API key, so it
# ships as a base64 tar.gz in the CLAUDE_HOME_TARBALL_B64 credential (see
# scripts/upload-credentials.sh --claude-home). Unpack it only when the
# persisted home volume has no credentials yet, so an existing — possibly
# token-refreshed — login is never overwritten. The blob is never echoed.
: "${HOME:=/home/claude-user}"
if [ -n "${CLAUDE_HOME_TARBALL_B64:-}" ] && [ ! -f "$HOME/.claude/.credentials.json" ]; then
    echo "entrypoint: restoring ~/.claude auth from the vault bundle" >&2
    mkdir -p "$HOME/.claude"
    printf '%s' "${CLAUDE_HOME_TARBALL_B64}" | base64 -d | tar -xzf - -C "$HOME/.claude"
fi

# Clone the repository on first run; reuse the volume afterwards.
if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all four harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint"
cd /workspace
mkdir -p /workspace/.claude

# Phase 4: render the GitHub MCP server config and safe auto-approvals from the
# templates baked into the image, substituting the injected token. The token
# lands inside a JSON string in mcp.json, and — now that arbitrary secrets flow
# through the credential store, and GITHUB_TOKEN is not a reserved credential
# name — its value can contain any byte. Escape in two stages so neither the
# JSON nor the sed substitution is corrupted:
#   0. strip C0 control bytes (0x00-0x1F) — a JSON string may not contain a raw
#      newline/tab/etc., so a token carrying one would otherwise produce invalid
#      JSON (#222). A real GITHUB_TOKEN never contains control bytes, so this is
#      a no-op for valid input and fails safe (a cleaned, then-invalid token
#      simply fails auth) for malformed input.
#   1. JSON-escape the value ('\' then '"') so it is a valid JSON string body.
#   2. sed-escape the result ('&', '|', '\') so sed writes it literally.
# Order matters: JSON-escaping adds backslashes that stage 2 must then protect.
if [ -f /etc/claude/mcp.json.template ] && [ ! -f /workspace/.claude/mcp.json ]; then
    gh_token_clean=$(printf '%s' "${GITHUB_TOKEN:-}" | tr -d '\000-\037')
    gh_token_json=$(printf '%s' "${gh_token_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    gh_token_escaped=$(printf '%s' "${gh_token_json}" | sed -e 's/[&|\\]/\\&/g')
    sed "s|\${GITHUB_TOKEN}|${gh_token_escaped}|g" \
        /etc/claude/mcp.json.template > /workspace/.claude/mcp.json

    # Phase 6 (docs/phase6-mcp-callbacks.md): register the cloud-agents MCP
    # server so the agent can request permission decisions / ask the human a
    # question / report progress mid-run. Gated behind
    # CLOUD_AGENTS_MCP_CALLBACKS until the shim binary (cloud-agents-shim,
    # built from shim/, stage 3) actually ships in this image — without the
    # gate, `claude` would try to spawn a nonexistent command on every run.
    # jq merges the base mcp.json with the rendered callbacks fragment so
    # both server entries coexist regardless of future additions to either
    # template.
    if [ "${CLOUD_AGENTS_MCP_CALLBACKS}" = "1" ] && [ -f /etc/claude/mcp-callbacks.json.template ] && command -v jq >/dev/null 2>&1; then
        api_url_clean=$(printf '%s' "${CLOUD_AGENTS_API_URL:-}" | tr -d '\000-\037')
        api_url_json=$(printf '%s' "${api_url_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        api_url_escaped=$(printf '%s' "${api_url_json}" | sed -e 's/[&|\\]/\\&/g')
        token_clean=$(printf '%s' "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" | tr -d '\000-\037')
        token_json=$(printf '%s' "${token_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        token_escaped=$(printf '%s' "${token_json}" | sed -e 's/[&|\\]/\\&/g')
        session_id_clean=$(printf '%s' "${NATIVE_SESSION_ID}" | tr -d '\000-\037')
        session_id_json=$(printf '%s' "${session_id_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        session_id_escaped=$(printf '%s' "${session_id_json}" | sed -e 's/[&|\\]/\\&/g')
        callbacks_fragment=$(sed \
            -e "s|\${CLOUD_AGENTS_API_URL}|${api_url_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_CALLBACK_TOKEN}|${token_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_SESSION_ID}|${session_id_escaped}|g" \
            /etc/claude/mcp-callbacks.json.template)
        merged=$(jq -s '.[0].mcpServers += .[1].mcpServers | .[0]' \
            /workspace/.claude/mcp.json <(printf '%s' "${callbacks_fragment}"))
        printf '%s' "${merged}" > /workspace/.claude/mcp.json
    fi
fi
if [ -f /etc/claude/settings.json.template ] && [ ! -f /workspace/.claude/settings.json ]; then
    cp /etc/claude/settings.json.template /workspace/.claude/settings.json
fi

# Very first invocation? Seed the session so --resume has history to attach to.
if [ ! -f /workspace/.claude/history.jsonl ]; then
    claude -p "Initialise session" --model "${MODEL}" --resume || true
fi

# Phase 6 (docs/phase6-mcp-callbacks.md §3): route Claude Code's own
# permission prompts through the cloud-agents MCP server instead of the
# static settings.json allowlist, so a tool call outside that allowlist pauses
# for a human decision instead of failing closed. Gated behind the same flag
# as the mcp.json registration above — an empty array is a no-op when the
# flag is off.
PERMISSION_PROMPT_ARGS=()
if [ "${CLOUD_AGENTS_MCP_CALLBACKS}" = "1" ]; then
    PERMISSION_PROMPT_ARGS=(--permission-prompt-tool "mcp__cloud-agents__request_permission")
fi

# Run the actual prompt. stdout is captured by the API server and streamed to
# the browser as SSE. Resume a specific session if NATIVE_SESSION_ID is set;
# otherwise resume the most recent session in the workspace volume.
if [ -n "$NATIVE_SESSION_ID" ]; then
    exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${NATIVE_SESSION_ID}" "${PERMISSION_PROMPT_ARGS[@]}"
else
    exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${PERMISSION_PROMPT_ARGS[@]}"
fi
