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

# Reconcile linked repositories under /workspace/repos (multi-repo sessions):
# clone any that are newly linked and remove any checkout that is no longer
# linked, so "Remove" in the UI takes the repo off disk on the next run (#460).
# EXTRA_REPOS is a space-separated list of "url|branch" entries (an empty
# branch — "url|" — means the repo's default branch). Values are validated
# server-side, so no space or '|' can appear inside a url or branch and
# word-splitting is safe; `set -f` disables globbing during the split so a
# '?'/'*' in a url can't be pathname-expanded. The reconcile also runs when
# EXTRA_REPOS is empty but /workspace/repos exists, so unlinking the last repo
# still prunes it.
if [ -n "${EXTRA_REPOS:-}" ] || [ -d /workspace/repos ]; then
    mkdir -p /workspace/repos
    wanted=""
    set -f
    for entry in ${EXTRA_REPOS:-}; do
        extra_url="${entry%%|*}"
        extra_branch="${entry#*|}"
        # A branchless entry (no '|') leaves the whole string in extra_branch;
        # normalise that to an empty branch. (The server always emits 'url|'.)
        [ "${extra_branch}" = "${entry}" ] && extra_branch=""
        [ -z "${extra_url}" ] && continue
        # Derive a collision-free directory from the whole URL, not just its
        # basename: two different repos sharing a basename (a/repo and b/repo)
        # would otherwise map to the same dir and the second clone would be
        # skipped (#450). Drop the scheme and a trailing .git, then slugify the
        # rest (host + path) to a filesystem-safe name.
        repo_slug=$(printf '%s' "${extra_url}" | sed -E -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/+$##' -e 's#\.git$##' -e 's#[^A-Za-z0-9._-]+#-#g' -e 's#^-+##' -e 's#-+$##')
        [ -z "${repo_slug}" ] && repo_slug="repo"
        wanted="${wanted} ${repo_slug}"
        repo_dir="/workspace/repos/${repo_slug}"
        if [ ! -d "${repo_dir}/.git" ]; then
            echo "entrypoint: cloning extra repo ${extra_url} (${extra_branch:-default branch})" >&2
            if [ -n "${extra_branch}" ]; then
                git clone "${extra_url}" --branch "${extra_branch}" "${repo_dir}"
            else
                git clone "${extra_url}" "${repo_dir}"
            fi
        fi
    done
    set +f
    # Prune checkouts that are no longer linked (globbing back on for the scan).
    for existing in /workspace/repos/*; do
        [ -e "${existing}" ] || continue
        base=$(basename "${existing}")
        case " ${wanted} " in
            *" ${base} "*) : ;;
            *) echo "entrypoint: removing unlinked repo ${base}" >&2; rm -rf "${existing}" ;;
        esac
    done
fi

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
