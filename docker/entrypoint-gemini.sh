#!/bin/bash
# Runner entrypoint for a single Gemini CLI invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - Gemini model to use (default: gemini-2.5-pro)
#   NATIVE_SESSION_ID - session ID for conversation continuity (reserved for Phase 2)
#   GEMINI_API_KEY    - Gemini API key (required; GOOGLE_API_KEY accepted as an alias)
#
# State persists across runs via two mounted volumes (#409):
#   /workspace          - the cloned repository (per-session volume)
#   /home/gemini-user   - Gemini CLI config and session history
#                         (gemini-home-default, mounted per harness — see
#                         CloudAgents.Db.homeVolumeBindForHarness)

set -euo pipefail

BRANCH="${BRANCH:-main}"
MODEL="${MODEL:-gemini-2.5-pro}"

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint-gemini: PROMPT is required" >&2
    exit 64
fi

# The Gemini CLI reads GEMINI_API_KEY; accept GOOGLE_API_KEY as an alias so a
# credential stored under either canonical name works.
if [ -z "${GEMINI_API_KEY:-}" ] && [ -n "${GOOGLE_API_KEY:-}" ]; then
    export GEMINI_API_KEY="${GOOGLE_API_KEY}"
fi
if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "entrypoint-gemini: GEMINI_API_KEY (or GOOGLE_API_KEY) is required" >&2
    exit 64
fi

if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint-gemini: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint-gemini: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

cd /workspace

# Non-interactive single invocation; --yolo auto-approves tool calls (the
# container itself is the sandbox, same trust model as the other harnesses).
exec gemini --model "${MODEL}" --yolo --prompt "${PROMPT}"
