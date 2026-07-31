#!/bin/bash
# Runner entrypoint for a single Gemini CLI invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - Gemini model to use (default: gemini-2.5-pro)
#   HARNESS           - harness identifier, e.g. "gemini" (required; used by
#                       create-fallback-branch.sh and inject-library.sh)
#   SESSION_ID        - cloud-agents session ID, distinct from NATIVE_SESSION_ID
#                       (required; used for fallback branch naming)
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

# Configure git credential helper and push defaults dynamically inside the container.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "entrypoint-gemini: configuring git credential helper for GitHub" >&2
    if [ "$(id -u)" -eq 0 ]; then
        git config --system credential.helper '!f() { cat >/dev/null; if [ "$1" = "get" ]; then echo "username=x-access-token"; echo "password=${GITHUB_TOKEN}"; fi; }; f'
        git config --system push.autoSetupRemote true
    else
        git config --global credential.helper '!f() { cat >/dev/null; if [ "$1" = "get" ]; then echo "username=x-access-token"; echo "password=${GITHUB_TOKEN}"; fi; }; f'
        git config --global push.autoSetupRemote true
    fi
fi

if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint-gemini: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint-gemini: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all four harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint-gemini"
cd /workspace

# Safety net: ensure we're not on the starting branch. Shared across all four
# harness entrypoints (#725) — see create-fallback-branch.sh.
create-fallback-branch.sh "entrypoint-gemini" "${HARNESS}" "${BRANCH}" "${SESSION_ID:-}"

# Render the session's profile-granted skills/subagents/MCP servers into
# Gemini CLI's own native config (docker/inject-library.sh). Reconciled every
# message; best-effort so a rendering hiccup never blocks the actual prompt
# run.
/usr/local/bin/inject-library.sh "gemini" || echo "entrypoint-gemini: library injection failed, continuing without it" >&2

# Register (or strip) the cloud-agents MCP callback shim in
# .gemini/settings.json, reconciled every message — gives Gemini CLI the
# add_todo/update_todo/report_progress/... tools
# (docker/register-callbacks-mcp.sh). Best-effort: a registration hiccup
# must never block the prompt run.
if [ -f /usr/local/bin/register-callbacks-mcp.sh ]; then
    # shellcheck source=register-callbacks-mcp.sh
    source /usr/local/bin/register-callbacks-mcp.sh
    register_callbacks_mcp "gemini" /workspace || echo "entrypoint-gemini: callback MCP registration failed, continuing without it" >&2
fi

# Non-interactive single invocation; --yolo auto-approves tool calls (the
# container itself is the sandbox, same trust model as the other harnesses).
exec gemini --model "${MODEL}" --yolo --prompt "${PROMPT}"
