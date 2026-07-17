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

if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint-opencode: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint-opencode: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Clone any additional linked repositories (multi-repo sessions). EXTRA_REPOS is
# a space-separated list of "url|branch" entries (an empty branch — "url|" —
# means the repo's default branch). Values are validated server-side, so no
# space or '|' can appear inside a url or branch and word-splitting is safe;
# `set -f` disables globbing so a '?'/'*' in a url can't be pathname-expanded.
# Each repo clones into /workspace/repos/<name> on first run and is reused from
# the persisted workspace volume afterwards, so the agent can work across repos.
if [ -n "${EXTRA_REPOS:-}" ]; then
    mkdir -p /workspace/repos
    set -f
    for entry in ${EXTRA_REPOS}; do
        extra_url="${entry%%|*}"
        extra_branch="${entry#*|}"
        [ "${extra_branch}" = "${entry}" ] && extra_branch=""
        [ -z "${extra_url}" ] && continue
        repo_dir="/workspace/repos/$(basename "${extra_url}" .git)"
        if [ ! -d "${repo_dir}/.git" ]; then
            echo "entrypoint-opencode: cloning extra repo ${extra_url} (${extra_branch:-default branch})" >&2
            if [ -n "${extra_branch}" ]; then
                git clone "${extra_url}" --branch "${extra_branch}" "${repo_dir}"
            else
                git clone "${extra_url}" "${repo_dir}"
            fi
        fi
    done
    set +f
fi

cd /workspace

exec opencode run --model "${MODEL}" -- "${PROMPT}"
