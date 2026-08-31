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
        _ca_tree_index="$(mktemp -u)"
        GIT_INDEX_FILE="${_ca_tree_index}" git add -A 2>/dev/null \
            && GIT_INDEX_FILE="${_ca_tree_index}" git write-tree 2>/dev/null
        rm -f "${_ca_tree_index}"
    }
}

fails=0
check() {
    local desc="$1"; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}
is_tree() { git -C "$1" cat-file -t "$2" 2>/dev/null | grep -qx tree; }

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
nohead_tree="$( cd "$N" && emit_tree )"
check "no-HEAD repo: emits a non-empty tree (F3 fallback)"   test -n "$nohead_tree"
check "no-HEAD repo: the emitted value is a real tree object" is_tree "$N" "$nohead_tree"
check "no-HEAD repo: still has no HEAD (never committed)"    bash -c "! git -C '$N' rev-parse HEAD >/dev/null 2>&1"

# ── 3. The fallback used a THROWAWAY index — the real index is untouched ──
# app.py was never `git add`ed to the real index, so it stays untracked.
check "no-HEAD repo: real index untouched (app.py still untracked)" \
    bash -c "git -C '$N' status --porcelain -- app.py | grep -q '^?? app.py$'"

# ── grep-pin: the entrypoint must still carry the F3 fallback ──
check "entrypoint.sh section 3 carries the git write-tree fallback" \
    grep -q "git write-tree" "$ENTRYPOINT"
check "entrypoint.sh section 3 uses a throwaway GIT_INDEX_FILE" \
    grep -q "GIT_INDEX_FILE" "$ENTRYPOINT"

if [ "$fails" -ne 0 ]; then
    echo "test-inspect-tree-fallback: $fails check(s) failed" >&2
    exit 1
fi
echo "test-inspect-tree-fallback: all checks passed"
