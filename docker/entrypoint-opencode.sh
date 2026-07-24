#!/bin/bash
# Runner entrypoint for a single OpenCode invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT              - the user's message text (required)
#   REPO_URL            - git remote to clone on first run (required)
#   BRANCH              - branch to check out (default: main)
#   MODEL               - model identifier, e.g. claude-sonnet-4-6 or gpt-4o (default: claude-sonnet-4-6)
#   NATIVE_SESSION_ID   - session ID for conversation continuity (reserved for Phase 2)
#   ANTHROPIC_API_KEY   - required when MODEL is a claude-* model
#   OPENAI_API_KEY      - required when MODEL is a gpt-* or o* model
#   GOOGLE_API_KEY      - required when MODEL is a gemini-* model
#
# State persists across runs via two mounted volumes:
#   /workspace            - the cloned repository
#   /home/opencode-user   - OpenCode config and session history

set -euo pipefail

BRANCH="${BRANCH:-main}"
MODEL="${MODEL:-claude-sonnet-4-6}"

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint-opencode: PROMPT is required" >&2
    exit 64
fi

# Validate that at least one API key is present for the selected model family.
case "$MODEL" in
  claude-*)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "entrypoint-opencode: ANTHROPIC_API_KEY is required for model $MODEL" >&2; exit 64; }
    ;;
  gpt-*|o[0-9]*)
    [ -n "${OPENAI_API_KEY:-}" ] || { echo "entrypoint-opencode: OPENAI_API_KEY is required for model $MODEL" >&2; exit 64; }
    ;;
  gemini-*)
    [ -n "${GOOGLE_API_KEY:-}" ] || { echo "entrypoint-opencode: GOOGLE_API_KEY is required for model $MODEL" >&2; exit 64; }
    ;;
  *)
    echo "entrypoint-opencode: no API key validation for unknown model family '$MODEL' — ensure the correct key is set" >&2
    ;;
esac

# OpenCode Zen expects OPENCODE_ZEN_API_KEY, but user credentials might define OPENCODE_API_KEY.
# Map OPENCODE_API_KEY to OPENCODE_ZEN_API_KEY if the latter is not already set.
export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-${OPENCODE_API_KEY:-}}"


if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint-opencode: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint-opencode: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all four harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint-opencode"
cd /workspace

# Render the session's profile-granted skills/subagents/MCP servers into
# OpenCode's own native config (docker/inject-library.sh). Reconciled every
# message; best-effort so a rendering hiccup never blocks the actual prompt
# run.
/usr/local/bin/inject-library.sh "opencode" || echo "entrypoint-opencode: library injection failed, continuing without it" >&2

exec opencode run --model "${MODEL}" -- "${PROMPT}"
