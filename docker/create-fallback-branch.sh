#!/bin/bash
# Shared fallback-branch safety net for every harness runner entrypoint (#725).
#
# After clone/reconcile, ensures we're not sitting on the starting branch.
# If the agent hasn't renamed the branch yet (first run or agent ignored
# instructions), creates a fallback working branch named
# <harness>/<session-id> so the starting branch stays clean. The agent's
# branch-policy rules instruct it to rename this to <harness>/<description>.
#
# Invoked by each entrypoint as: create-fallback-branch.sh <log-prefix> <harness> <branch> [session-id] [workspace-root]
# All args are positional (not env vars) so the script can be tested without
# container injection, matching reconcile-repos.sh convention.
set -euo pipefail

prefix="${1:?create-fallback-branch.sh: log-prefix required}"
harness="${2:?create-fallback-branch.sh: harness required}"
branch="${3:?create-fallback-branch.sh: starting branch required}"
session_id="${4:-}"
ws="${5:-/workspace}"

if [ ! -d "$ws/.git" ]; then
    exit 0
fi

current=$(git -C "$ws" branch --show-current 2>/dev/null || echo "")

# Already off the starting branch — nothing to do.
if [ "$current" != "$branch" ] && [ -n "$current" ]; then
    exit 0
fi

fallback_branch="${harness}/${session_id:-$(date +%s)}"
if git -C "$ws" checkout -b "${fallback_branch}" 2>/tmp/fallback-branch-err; then
    echo "${prefix}: created fallback working branch ${fallback_branch}" >&2
else
    echo "${prefix}: WARNING: failed to create fallback branch ${fallback_branch}:" >&2
    cat /tmp/fallback-branch-err >&2
    echo "${prefix}: WARNING: continuing on current branch '${current:-detached HEAD}' — the starting branch may be modified" >&2
    rm -f /tmp/fallback-branch-err
fi
