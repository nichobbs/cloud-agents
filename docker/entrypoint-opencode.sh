#!/bin/bash
# Runner entrypoint for a single OpenCode invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT              - the user's message text (required)
#   REPO_URL            - git remote to clone on first run (required)
#   BRANCH              - branch to check out (default: main)
#   MODEL               - model identifier, e.g. claude-sonnet-4-6 or gpt-4o (default: claude-sonnet-4-6)
#   HARNESS             - harness identifier, e.g. "opencode" (required; used by
#                         create-fallback-branch.sh and inject-library.sh)
#   SESSION_ID          - cloud-agents session ID, distinct from NATIVE_SESSION_ID
#                         (required; used for fallback branch naming)
#   NATIVE_SESSION_ID   - session ID for conversation continuity (reserved for Phase 2)
#   ANTHROPIC_API_KEY   - required when MODEL is a claude-* model
#   OPENAI_API_KEY      - required when MODEL is a gpt-* or o* model
#   GOOGLE_API_KEY      - required when MODEL is a gemini-* model
#
# State persists across runs via two mounted volumes:
#   /workspace            - the cloned repository
#   /home/opencode-user   - OpenCode config and session history

set -euo pipefail

# Workspace-inspect mode (workspace inspector, src/handlers/workspace.l):
# when CLOUD_AGENTS_INSPECT_MODE is set this container is a short-lived,
# read-only look at /workspace — the API server started it with NO
# credentials, NO home volume, and NetworkMode "none"
# (docker_manager.l's runInspectContainer), so nothing below this block
# (credential helpers, clone, harness launch) may run. Prints the
# CLOUD_AGENTS_INSPECT_OK / ===CLOUD_AGENTS_SECTION=== /
# CLOUD_AGENTS_INSPECT_ERR marker protocol that the pure
# CloudAgents.Workspace package parses out of the container logs — keep the
# two in byte-for-byte sync — and ALWAYS exits 0 so waitForContainer treats
# the run as complete. Every command is guarded so `set -e`/pipefail can
# never kill the script before a marker is printed (e.g. `head -5000`
# SIGPIPE-ing `git ls-files` under pipefail).
if [ -n "${CLOUD_AGENTS_INSPECT_MODE:-}" ]; then
    if [ ! -d /workspace/.git ]; then
        # The workspace volume auto-creates on bind, so it always mounts —
        # but no run has ever cloned a repo into it yet.
        echo "CLOUD_AGENTS_INSPECT_ERR no workspace"
        exit 0
    fi
    cd /workspace || { echo "CLOUD_AGENTS_INSPECT_ERR no workspace"; exit 0; }
    # The checkout is typically owned by the harness user while inspect runs
    # as root; without this, modern git refuses with "dubious ownership".
    # The normal-run path sidesteps that by chown-ing — inspect stays
    # read-only instead.
    git config --global --add safe.directory /workspace >/dev/null 2>&1 || true
    case "${CLOUD_AGENTS_INSPECT_MODE}" in
        diff)
            echo "CLOUD_AGENTS_INSPECT_OK"
            git status --porcelain || true
            echo "===CLOUD_AGENTS_SECTION==="
            { git diff HEAD --numstat 2>/dev/null || git diff --numstat; } || true
            echo "===CLOUD_AGENTS_SECTION==="
            { git diff HEAD 2>/dev/null || git diff; } || true
            ;;
        tree)
            echo "CLOUD_AGENTS_INSPECT_OK"
            { git ls-files --cached --others --exclude-standard | head -5000; } || true
            ;;
        file)
            if [ -f "${CLOUD_AGENTS_INSPECT_PATH:-}" ]; then
                echo "CLOUD_AGENTS_INSPECT_OK"
                wc -c < "${CLOUD_AGENTS_INSPECT_PATH}" || true
                echo "===CLOUD_AGENTS_SECTION==="
                { head -c 1048576 "${CLOUD_AGENTS_INSPECT_PATH}" | base64; } || true
            else
                echo "CLOUD_AGENTS_INSPECT_ERR not found"
            fi
            ;;
        *)
            echo "CLOUD_AGENTS_INSPECT_ERR bad mode"
            ;;
    esac
    exit 0
fi

BRANCH="${BRANCH:-main}"
MODEL="${MODEL:-claude-sonnet-4-6}"

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint-opencode: PROMPT is required" >&2
    exit 64
fi

# Map legacy/unqualified free OpenCode models to the qualified 'opencode/' provider prefix.
case "$MODEL" in
  big-pickle|deepseek-v4-flash-free|hy3-free|mimo-v2.5-free|nemotron-3-ultra-free|north-mini-code-free)
    MODEL="opencode/${MODEL}"
    ;;
esac

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
  opencode/*)
    # Free models — no key required, but we will default it below if none is set
    ;;
  *)
    echo "entrypoint-opencode: no API key validation for unknown model family '$MODEL' — ensure the correct key is set" >&2
    ;;
esac

# OpenCode Zen expects OPENCODE_ZEN_API_KEY, but user credentials might define OPENCODE_API_KEY.
# Map OPENCODE_API_KEY to OPENCODE_ZEN_API_KEY if the latter is not already set.
export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-${OPENCODE_API_KEY:-}}"

# Default key for free models under the 'opencode/' provider if none configured so they work out of the box
case "$MODEL" in
  opencode/*)
    export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-free-model-placeholder}"
    ;;
esac


# Configure git credential helper and push defaults dynamically inside the container.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "entrypoint-opencode: configuring git credential helper for GitHub" >&2
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
        echo "entrypoint-opencode: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint-opencode: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all five harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint-opencode"
cd /workspace

# Safety net: ensure we're not on the starting branch. Shared across all five
# harness entrypoints (#725) — see create-fallback-branch.sh.
create-fallback-branch.sh "entrypoint-opencode" "${HARNESS}" "${BRANCH}" "${SESSION_ID:-}"

# Render the session's profile-granted skills/subagents/MCP servers into
# OpenCode's own native config (docker/inject-library.sh). Reconciled every
# message; best-effort so a rendering hiccup never blocks the actual prompt
# run.
/usr/local/bin/inject-library.sh "opencode" || echo "entrypoint-opencode: library injection failed, continuing without it" >&2

# Register (or strip) the cloud-agents MCP callback shim in opencode.json,
# reconciled every message — gives OpenCode the add_todo/update_todo/
# report_progress/... tools (docker/register-callbacks-mcp.sh). Best-effort:
# a registration hiccup must never block the prompt run.
if [ -f /usr/local/bin/register-callbacks-mcp.sh ]; then
    # shellcheck source=register-callbacks-mcp.sh
    source /usr/local/bin/register-callbacks-mcp.sh
    register_callbacks_mcp "opencode" /workspace || echo "entrypoint-opencode: callback MCP registration failed, continuing without it" >&2
fi

exec opencode run --model "${MODEL}" --format json -q -- "${PROMPT}"
