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

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint: PROMPT is required" >&2
    exit 64
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

cd /workspace
mkdir -p /workspace/.claude

# Phase 4: render the GitHub MCP server config and safe auto-approvals from the
# templates baked into the image, substituting the injected token. The token
# lands inside a JSON string in mcp.json, and — now that arbitrary secrets flow
# through the credential store, and GITHUB_TOKEN is not a reserved credential
# name — its value can contain any byte. Escape in two stages so neither the
# JSON nor the sed substitution is corrupted:
#   1. JSON-escape the value ('\' then '"') so it is a valid JSON string body.
#   2. sed-escape the result ('&', '|', '\') so sed writes it literally.
# Order matters: JSON-escaping adds backslashes that stage 2 must then protect.
if [ -f /etc/claude/mcp.json.template ] && [ ! -f /workspace/.claude/mcp.json ]; then
    gh_token_json=$(printf '%s' "${GITHUB_TOKEN:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    gh_token_escaped=$(printf '%s' "${gh_token_json}" | sed -e 's/[&|\\]/\\&/g')
    sed "s|\${GITHUB_TOKEN}|${gh_token_escaped}|g" \
        /etc/claude/mcp.json.template > /workspace/.claude/mcp.json
fi
if [ -f /etc/claude/settings.json.template ] && [ ! -f /workspace/.claude/settings.json ]; then
    cp /etc/claude/settings.json.template /workspace/.claude/settings.json
fi

# Very first invocation? Seed the session so --resume has history to attach to.
if [ ! -f /workspace/.claude/history.jsonl ]; then
    claude -p "Initialise session" --model "${MODEL}" --resume || true
fi

# Run the actual prompt. stdout is captured by the API server and streamed to
# the browser as SSE. Resume a specific session if NATIVE_SESSION_ID is set;
# otherwise resume the most recent session in the workspace volume.
if [ -n "$NATIVE_SESSION_ID" ]; then
    exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${NATIVE_SESSION_ID}"
else
    exec claude -p "${PROMPT}" --model "${MODEL}" --resume
fi
