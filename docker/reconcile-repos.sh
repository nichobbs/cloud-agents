#!/bin/bash
# Shared multi-repo reconcile for every harness runner entrypoint (#468 — this
# was previously duplicated near-verbatim in all four entrypoint*.sh scripts).
#
# Clones the repositories currently linked to the session and prunes any
# checkout that is no longer linked, under /workspace/repos — so "Add repository"
# takes effect on the next run and "Remove" takes the checkout off disk. An
# agent can then work across several repositories in one run.
#
# Invoked by each entrypoint as: reconcile-repos.sh <log-prefix> [workspace-root]
# The workspace root is a positional arg (default /workspace) rather than an env
# var, so the reconcile can be exercised against a temp dir in a test without
# introducing a new container-injectable variable. Reads EXTRA_REPOS from the
# environment: a space-separated list of "url|branch" entries (an empty branch —
# "url|" — means the repo's default branch). Values are validated server-side,
# so no space or '|' can appear inside a url or branch and word-splitting is
# safe; `set -f` disables globbing during the split so a '?'/'*' in a url can't
# be pathname-expanded.
set -euo pipefail

prefix="${1:-entrypoint}"
repos_dir="${2:-/workspace}/repos"

# Nothing linked and no existing checkouts to prune -> nothing to do. (Runs even
# when EXTRA_REPOS is empty but the repos dir exists, so unlinking the last repo
# still prunes it.)
if [ -z "${EXTRA_REPOS:-}" ] && [ ! -d "${repos_dir}" ]; then
    exit 0
fi

mkdir -p "${repos_dir}"
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
    # would otherwise map to the same dir and the second clone would be skipped.
    # Drop the scheme and a trailing .git, then slugify the rest (host + path)
    # to a filesystem-safe name.
    repo_slug=$(printf '%s' "${extra_url}" | sed -E -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/+$##' -e 's#\.git$##' -e 's#[^A-Za-z0-9._-]+#-#g' -e 's#^-+##' -e 's#-+$##')
    [ -z "${repo_slug}" ] && repo_slug="repo"
    wanted="${wanted} ${repo_slug}"
    repo_dir="${repos_dir}/${repo_slug}"
    if [ ! -d "${repo_dir}/.git" ]; then
        echo "${prefix}: cloning extra repo ${extra_url} (${extra_branch:-default branch})" >&2
        if [ -n "${extra_branch}" ]; then
            git clone "${extra_url}" --branch "${extra_branch}" "${repo_dir}"
        else
            git clone "${extra_url}" "${repo_dir}"
        fi
    fi
done
set +f

# Prune checkouts that are no longer linked (globbing back on for the scan).
for existing in "${repos_dir}"/*; do
    [ -e "${existing}" ] || continue
    base=$(basename "${existing}")
    case " ${wanted} " in
        *" ${base} "*) : ;;
        *) echo "${prefix}: removing unlinked repo ${base}" >&2; rm -rf "${existing}" ;;
    esac
done
