#!/bin/bash
# Runner entrypoint for a single Codex CLI invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - OpenAI model to use (default: o4-mini)
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
            echo "entrypoint-codex: cloning extra repo ${extra_url} (${extra_branch:-default branch})" >&2
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
            *) echo "entrypoint-codex: removing unlinked repo ${base}" >&2; rm -rf "${existing}" ;;
        esac
    done
fi

cd /workspace

exec codex --model "${MODEL}" --full-auto -- "${PROMPT}"
