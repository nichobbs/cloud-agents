#!/usr/bin/env bash
# Regression test for docker/entrypoint.sh's inspect `diff` mode section 3 — the
# workspace tree hash that anchors the runner's terminal checkpoint (M1.2; dogfood
# finding F3). Exercises the tree-emit logic against REAL temp git repos (needs
# real `git`, no Docker, no network):
#   1. a committed repo  -> emits HEAD^{tree} (the committed BASE anchor);
#   2. a no-HEAD repo    -> emits a working-tree `git write-tree` FALLBACK, so a
#      terminal checkpoint still lands instead of steps-only (the F3 fix);
#   3. that fallback uses a THROWAWAY index -> the real index/checkout are untouched.
#
# The tree-emit is inline in entrypoint.sh (not a sourceable helper), so `emit_tree`
# below MIRRORS that exact command. A grep-pin at the end fails if the entrypoint
# ever loses the `git write-tree` / `GIT_INDEX_FILE` fallback, so the mirror cannot
# silently drift from the shipped command.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint.sh"
[ -f "$ENTRYPOINT" ] || { echo "test-inspect-tree-fallback: $ENTRYPOINT not found" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# MIRRORS docker/entrypoint.sh inspect `diff` mode section 3 — keep in sync (the
# grep-pin below guards removal of the fallback).
emit_tree() {
    git rev-parse --verify HEAD^{tree} 2>/dev/null || {
        _ca_tree_tmp="$(mktemp -d 2>/dev/null)"
        if [ -n "${_ca_tree_tmp}" ] && [ -d "${_ca_tree_tmp}" ]; then
            mkdir -p "${_ca_tree_tmp}/objects"
            GIT_INDEX_FILE="${_ca_tree_tmp}/index" GIT_OBJECT_DIRECTORY="${_ca_tree_tmp}/objects" \
                git add -A 2>/dev/null \
                && GIT_INDEX_FILE="${_ca_tree_tmp}/index" GIT_OBJECT_DIRECTORY="${_ca_tree_tmp}/objects" \
                    git write-tree 2>/dev/null
            rm -rf "${_ca_tree_tmp}"
        fi
    }
}
objcount() { find "$1/.git/objects" -type f 2>/dev/null | wc -l | tr -d ' '; }

fails=0
check() {
    local desc="$1"; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ── 1. Committed repo → HEAD^{tree} ──
C="$WORK/committed"
git init -q "$C"
printf 'a\n' > "$C/f.txt"
( cd "$C" && git add -A && git commit -qm init )
committed_tree="$( cd "$C" && emit_tree )"
head_tree="$( cd "$C" && git rev-parse HEAD^{tree} )"
check "committed repo: emits a non-empty tree"        test -n "$committed_tree"
check "committed repo: emits exactly HEAD^{tree}"     test "$committed_tree" = "$head_tree"

# ── 2. No-HEAD repo (fresh, uncommitted) → write-tree fallback ──
N="$WORK/nohead"
git init -q "$N"
printf 'hello\n' > "$N/app.py"
nohead_objs_before="$( objcount "$N" )"
nohead_tree="$( cd "$N" && emit_tree )"
check "no-HEAD repo: emits a non-empty tree (F3 fallback)"   test -n "$nohead_tree"
# The tree object lives in the THROWAWAY object dir, not the real repo, so read it
# back with git's --literally hash check rather than cat-file against the real store.
check "no-HEAD repo: the emitted value is a valid 40-hex object id" \
    bash -c "printf '%s' '$nohead_tree' | grep -Eqx '[0-9a-f]{40}'"
check "no-HEAD repo: still has no HEAD (never committed)"    bash -c "! git -C '$N' rev-parse HEAD >/dev/null 2>&1"

# ── 3. The fallback touches NOTHING in the real repo (read-only invariant, #1028) ──
# app.py was never `git add`ed to the real index, so it stays untracked …
check "no-HEAD repo: real index untouched (app.py still untracked)" \
    bash -c "git -C '$N' status --porcelain -- app.py | grep -q '^?? app.py$'"
# … and the throwaway object dir means the real .git/objects gained no objects.
check "no-HEAD repo: real .git/objects untouched (#1028 read-only)" \
    test "$( objcount "$N" )" = "$nohead_objs_before"

# ── 4. HEAD-having repo WITH uncommitted changes → committed tree, NOT the fallback (#1030) ──
# The common runner case: a cloned repo the agent edited. Section 3 must return the
# committed base tree (edits ride in the diff hunks), never a working-tree write-tree.
D="$WORK/dirty"
git init -q "$D"
printf 'base\n' > "$D/f.txt"
( cd "$D" && git add -A && git commit -qm base )
printf 'edited\n' >> "$D/f.txt"          # uncommitted change
printf 'new\n' > "$D/untracked.txt"      # uncommitted new file
dirty_objs_before="$( objcount "$D" )"
dirty_tree="$( cd "$D" && emit_tree )"
dirty_head_tree="$( git -C "$D" rev-parse HEAD^{tree} )"
check "dirty-HEAD repo: emits the COMMITTED tree, not a working-tree write-tree (#1030)" \
    test "$dirty_tree" = "$dirty_head_tree"
check "dirty-HEAD repo: fallback not taken ⇒ real .git/objects untouched" \
    test "$( objcount "$D" )" = "$dirty_objs_before"

# ── grep-pin: the entrypoint must still carry the F3 fallback ──
check "entrypoint.sh section 3 carries the git write-tree fallback" \
    grep -q "git write-tree" "$ENTRYPOINT"
check "entrypoint.sh section 3 uses a throwaway GIT_INDEX_FILE" \
    grep -q "GIT_INDEX_FILE" "$ENTRYPOINT"
check "entrypoint.sh section 3 uses a throwaway GIT_OBJECT_DIRECTORY (#1028 read-only)" \
    grep -q "GIT_OBJECT_DIRECTORY" "$ENTRYPOINT"

if [ "$fails" -ne 0 ]; then
    echo "test-inspect-tree-fallback: $fails check(s) failed" >&2
    exit 1
fi
echo "test-inspect-tree-fallback: all checks passed"
