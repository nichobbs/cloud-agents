#!/bin/bash
# Runner entrypoint for a single Codex CLI invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - OpenAI model to use (default: o4-mini)
#   HARNESS           - harness identifier, e.g. "codex" (required; used by
#                       create-fallback-branch.sh and inject-library.sh)
#   SESSION_ID        - cloud-agents session ID, distinct from NATIVE_SESSION_ID
#                       (required; used for fallback branch naming)
#   NATIVE_SESSION_ID - session ID for conversation continuity (reserved for Phase 2)
#   OPENAI_API_KEY    - OpenAI API key (required)
#
# State persists across runs via two mounted volumes:
#   /workspace        - the cloned repository
#   /home/codex-user  - Codex CLI config and session history

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
MODEL="${MODEL:-o4-mini}"

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint-codex: PROMPT is required" >&2
    exit 64
fi
if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "entrypoint-codex: OPENAI_API_KEY is required" >&2
    exit 64
fi

# Configure git credential helper and push defaults dynamically inside the container.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "entrypoint-codex: configuring git credential helper for GitHub" >&2
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
        echo "entrypoint-codex: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint-codex: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all four harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint-codex"
cd /workspace

# Safety net: ensure we're not on the starting branch. Shared across all four
# harness entrypoints (#725) — see create-fallback-branch.sh.
create-fallback-branch.sh "entrypoint-codex" "${HARNESS}" "${BRANCH}" "${SESSION_ID:-}"

# Render the session's profile-granted skills/subagents/MCP servers into
# Codex's own native config (docker/inject-library.sh). Reconciled every
# message; best-effort so a rendering hiccup never blocks the actual prompt
# run.
/usr/local/bin/inject-library.sh "codex" || echo "entrypoint-codex: library injection failed, continuing without it" >&2

# Register (or strip) the cloud-agents MCP callback shim in
# .codex/config.toml, reconciled every message — gives Codex the add_todo/
# update_todo/report_progress/... tools (docker/register-callbacks-mcp.sh).
# Best-effort: a registration hiccup must never block the prompt run.
if [ -f /usr/local/bin/register-callbacks-mcp.sh ]; then
    # shellcheck source=register-callbacks-mcp.sh
    source /usr/local/bin/register-callbacks-mcp.sh
    register_callbacks_mcp "codex" /workspace || echo "entrypoint-codex: callback MCP registration failed, continuing without it" >&2
fi

# Codex reads its config from $CODEX_HOME (default ~/.codex), NOT the
# workspace — point it at the workspace .codex/ that this entrypoint and
# inject-library.sh actually write (#808), so the MCP registration and the
# library-granted subagents/servers rendered there are genuinely
# discovered. Auth is env-based here (OPENAI_API_KEY) and each run is
# stateless, so nothing in the default ~/.codex is lost by the override.
export CODEX_HOME=/workspace/.codex

# Codex can't use a rules file for branch policy (it would override the
# user's AGENTS.md), so the instruction is prepended to the prompt instead.
# Always send it — Codex is stateless (no conversation continuity), so
# there's no way to know if a previous message already handled the rename.
# The instruction itself says "rename the current branch", which is safe to
# repeat: if already on a descriptive branch, Codex will just rename it
# again (harmless) or leave it (if it judges the name adequate).
CODEX_BRANCH_INSTRUCTION="BRANCH POLICY: Before making any changes, rename the current branch using: git branch -m codex/<short-description>. Push with: git push -u origin <branch-name>. Never work on the starting branch.

"
# Session-visibility conventions (docker/session-tools-guide.md) — Codex
# can't discover a rules file (see above), so a condensed version rides the
# same prompt prefix: a parseable checkbox plan the UI's todo panel shows,
# and a Session notes section the highlights summarizer mines.
CODEX_SESSION_INSTRUCTION="SESSION VISIBILITY: For multi-step tasks, maintain a live plan the human can watch: if the cloud-agents MCP tools are available, use add_todo to create one item per step, update_todo to mark each in_progress when you start it and done when finished, and list_todos when resuming. If those tools are unavailable, instead restate your plan at the END of each response as a markdown checkbox list (- [ ] pending, - [~] in progress, - [x] done; one item per line, at least two items) — the session UI parses and displays it. Either way, end your final response with a '## Session notes' section listing (as short, specific bullets) any unexpected discoveries, issues/tickets opened or closed (with number/URL), workarounds, reverts, and incomplete or skipped work; omit the section only if none apply.

"
exec codex --model "${MODEL}" --full-auto -- "${CODEX_BRANCH_INSTRUCTION}${CODEX_SESSION_INSTRUCTION}${PROMPT}"
