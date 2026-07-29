#!/usr/bin/env bash
# Regression test for docker/create-fallback-branch.sh (#725). Exercises the
# fallback-branch safety-net logic against a temp workspace with a real git
# repo, so it needs neither Docker nor the network. Runs the REAL script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/docker/create-fallback-branch.sh"
[ -f "$SCRIPT" ] || { echo "test-create-fallback-branch: $SCRIPT not found" >&2; exit 1; }

WORK="$(mktemp -d)"
WS="$WORK/ws"
mkdir -p "$WS"
git -C "$WS" init -q --initial-branch=main
git -C "$WS" config user.email "test@test.com"
git -C "$WS" config user.name "test"
echo "init" > "$WS/README.md"
git -C "$WS" add . && git -C "$WS" commit -q -m "init"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

current_branch() { git -C "$WS" branch --show-current 2>/dev/null || echo ""; }
run_script() { "$SCRIPT" "test" "$1" "main" "$2" "$WS" >/dev/null 2>&1; }

# Test 1: On starting branch -> creates fallback with session ID
run_script "claude" "sess-abc123"
check "t1: creates fallback branch"       bash -c "[ \"$(current_branch)\" = 'claude/sess-abc123' ]"

# Reset: go back to main
git -C "$WS" checkout -q main
git -C "$WS" branch -D "claude/sess-abc123" 2>/dev/null || true

# Test 2: Already on a different branch -> no-op
git -C "$WS" checkout -q -b "claude/existing-work"
run_script "claude" "sess-xyz"
check "t2: stays on existing branch"      bash -c "[ \"$(current_branch)\" = 'claude/existing-work' ]"

# Reset
git -C "$WS" checkout -q main
git -C "$WS" branch -D "claude/existing-work" 2>/dev/null || true

# Test 3: No session ID -> uses timestamp fallback (branch name contains harness/)
run_script "opencode" ""
BRANCH_NAME="$(current_branch)"
check "t3: fallback has harness prefix"   bash -c "[[ \"$BRANCH_NAME\" == opencode/* ]]"
check "t3: branch exists"                 bash -c "[ -n \"$BRANCH_NAME\" ]"

# Reset
git -C "$WS" checkout -q main
git -C "$WS" branch -D "$BRANCH_NAME" 2>/dev/null || true

# Test 4: No .git directory -> clean exit 0
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
check "t4: no .git -> clean exit"         bash -c "'$SCRIPT' 'test' 'claude' 'main' 'x' '$EMPTY' >/dev/null 2>&1"

# Test 5: Detached HEAD -> creates fallback
git -C "$WS" checkout -q --detach HEAD
run_script "gemini" "sess-det"
check "t5: detached HEAD -> creates"      bash -c "[ \"$(current_branch)\" = 'gemini/sess-det' ]"

# Reset
git -C "$WS" checkout -q main
git -C "$WS" branch -D "gemini/sess-det" 2>/dev/null || true

# Test 6: Branch exists from prior run, but we're on starting branch -> warns
# (simulates a partial prior run where the checkout failed mid-way)
"$SCRIPT" "test" "codex" "main" "sess-dup" "$WS" >/dev/null 2>&1 || true
git -C "$WS" checkout -q main 2>/dev/null || true
OUTPUT=$("$SCRIPT" "test" "codex" "main" "sess-dup" "$WS" 2>&1) || true
check "t6: stale branch -> warning"       bash -c "[[ \"$OUTPUT\" == *WARNING* ]]"

if [ "$fails" -ne 0 ]; then
  echo "==> test-create-fallback-branch: ${fails} check(s) failed" >&2
  exit 1
fi
echo "==> test-create-fallback-branch: all checks passed"
