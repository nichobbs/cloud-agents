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

# Codex can't use a rules file for branch policy (it would override the
# user's AGENTS.md), so the instruction is prepended to the prompt instead.
# Always send it — Codex is stateless (no conversation continuity), so
# there's no way to know if a previous message already handled the rename.
# The instruction itself says "rename the current branch", which is safe to
# repeat: if already on a descriptive branch, Codex will just rename it
# again (harmless) or leave it (if it judges the name adequate).
CODEX_BRANCH_INSTRUCTION="BRANCH POLICY: Before making any changes, rename the current branch using: git branch -m codex/<short-description>. Push with: git push -u origin <branch-name>. Never work on the starting branch.

"
exec codex --model "${MODEL}" --full-auto -- "${CODEX_BRANCH_INSTRUCTION}${PROMPT}"
