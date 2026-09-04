#!/usr/bin/env bash
# Regression test for docker/entrypoint.sh's NATIVE_SESSION_MARKER state
# machine (#710's self-heal fix), covering #709/#717.
#
# entrypoint.sh cannot be sourced or exec'd for real here: it hardcodes
# absolute paths throughout (/workspace, /home/claude-user,
# /usr/local/bin/reconcile-repos.sh, /usr/local/bin/inject-library.sh,
# /etc/claude/*.template — see the owner's comment on #709), and its final
# step in every branch is `exec runuser -u claude-user -- claude ...`, which
# needs both `runuser` and a real `claude` binary. Refactoring it to take
# parameters the way docker/reconcile-repos.sh does would be a separate,
# larger change than a regression test should require (also per that same
# comment).
#
# Instead this MIRRORS the exact branching logic (marker-file presence x
# NATIVE_SESSION_ID presence x the #710 self-heal transcript lookup) in a
# small, parameterized function and tests it against real temp dirs — same
# technique scripts/test-inspect-tree-fallback.sh already uses for
# entrypoint.sh's inspect-mode tree-hash section: a grep-pin at the end fails
# if the real file's decision shape ever drifts from what's mirrored here, so
# the mirror can't quietly go stale.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint.sh"
[ -f "$ENTRYPOINT" ] || { echo "test-entrypoint-session-resume: $ENTRYPOINT not found" >&2; exit 1; }

# MIRRORS docker/entrypoint.sh's NATIVE_SESSION_MARKER decision logic — keep
# in sync (the grep-pin below guards against silent drift). Prints which
# `claude` invocation SHAPE would be chosen (not a full command line):
#   session-id:ID       - fresh session, first-ever invocation for this ID
#   resume:ID           - marker present -> --resume ID
#   resume-selfheal:ID  - marker absent but the CLI already has a transcript
#                         for ID on the home volume (#710 self-heal)
#   bare                - marker absent, no NATIVE_SESSION_ID at all
#   resume-bare         - marker present, no NATIVE_SESSION_ID (unreachable
#                         in production; entrypoint.sh keeps an equivalent
#                         branch anyway, so this mirrors it too)
decide_invocation() {
    local marker="$1" native_session_id="$2" claude_home="$3"
    if [ ! -f "$marker" ]; then
        if [ -n "$native_session_id" ]; then
            if [ -n "$(find "$claude_home/.claude/projects" -name "${native_session_id}.jsonl" 2>/dev/null | head -n 1)" ]; then
                echo "resume-selfheal:${native_session_id}"
            else
                echo "session-id:${native_session_id}"
            fi
        else
            echo "bare"
        fi
    else
        if [ -n "$native_session_id" ]; then
            echo "resume:${native_session_id}"
        else
            echo "resume-bare"
        fi
    fi
}

fails=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}
eq() { [ "$1" = "$2" ]; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ── Case 1: message 1 — brand-new workspace, no marker, no prior transcript
# anywhere on the home volume -> --session-id ──────────────────────────────
W1="$WORK/case1"
mkdir -p "$W1/.claude" "$W1/home/.claude/projects"
result="$(decide_invocation "$W1/.claude/.native-session-initialized" "abc-123" "$W1/home")"
check "message 1, fresh session -> --session-id" eq "$result" "session-id:abc-123"

# ── Case 2: message 2+ — marker already present -> --resume ────────────────
W2="$WORK/case2"
mkdir -p "$W2/.claude" "$W2/home/.claude/projects"
touch "$W2/.claude/.native-session-initialized"
result="$(decide_invocation "$W2/.claude/.native-session-initialized" "abc-123" "$W2/home")"
check "message 2+, marker present -> --resume" eq "$result" "resume:abc-123"

# ── Case 3: #710 self-heal — this /workspace predates the marker scheme (no
# marker), but the *shared* home volume already has a transcript for this
# session ID from before the fix shipped -> --resume, never --session-id
# (which the CLI would reject as already-in-use, reproducing #710) ─────────
W3="$WORK/case3"
mkdir -p "$W3/.claude" "$W3/home/.claude/projects/some-slug"
touch "$W3/home/.claude/projects/some-slug/abc-123.jsonl"
result="$(decide_invocation "$W3/.claude/.native-session-initialized" "abc-123" "$W3/home")"
check "#710 self-heal: no marker but a transcript exists -> --resume" \
    eq "$result" "resume-selfheal:abc-123"

# ── Case 4: a completely fresh home volume too (no ~/.claude/projects tree
# at all yet) -> --session-id, same as case 1 ───────────────────────────────
W4="$WORK/case4"
mkdir -p "$W4/.claude" "$W4/home"
result="$(decide_invocation "$W4/.claude/.native-session-initialized" "abc-123" "$W4/home")"
check "fresh home volume, no projects dir at all -> --session-id" \
    eq "$result" "session-id:abc-123"

# ── grep-pin: the real entrypoint must still carry this exact decision shape ──
check "entrypoint.sh still keys off NATIVE_SESSION_MARKER" \
    grep -q "NATIVE_SESSION_MARKER" "$ENTRYPOINT"
check "entrypoint.sh still does the #710 self-heal transcript lookup" \
    grep -q 'find "\$HOME/.claude/projects" -name "\${NATIVE_SESSION_ID}.jsonl"' "$ENTRYPOINT"
check "entrypoint.sh still branches --session-id vs --resume on the marker" \
    bash -c "grep -q -- '--session-id \"\${NATIVE_SESSION_ID}\"' '$ENTRYPOINT' && grep -q -- '--resume \"\${NATIVE_SESSION_ID}\"' '$ENTRYPOINT'"

if [ "$fails" -ne 0 ]; then
    echo "test-entrypoint-session-resume: $fails check(s) failed" >&2
    exit 1
fi
echo "test-entrypoint-session-resume: all checks passed"
