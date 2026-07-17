#!/usr/bin/env bash
# Regression test for docker/reconcile-repos.sh (#471). Exercises the
# clone-linked / prune-unlinked logic against a temp workspace with a mock `git`
# on PATH, so it needs neither Docker nor the network. Runs the REAL script
# (via its workspace-root positional arg), not a copy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/docker/reconcile-repos.sh"
[ -f "$SCRIPT" ] || { echo "test-reconcile: $SCRIPT not found" >&2; exit 1; }

WORK="$(mktemp -d)"
BIN="$WORK/bin"
WS="$WORK/ws"
mkdir -p "$BIN" "$WS/repos"

# Mock git: `git clone [--branch B] URL DIR` just creates DIR/.git.
cat > "$BIN/git" <<'MOCK'
#!/bin/bash
args=("$@"); dir="${args[-1]}"; mkdir -p "$dir/.git"
MOCK
chmod +x "$BIN/git"
export PATH="$BIN:$PATH"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

run() { EXTRA_REPOS="$1" "$SCRIPT" "test" "$WS" >/dev/null 2>&1; }
present() { [ -d "$WS/repos/$1/.git" ]; }
fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

# Round 1: link two repos (one branch, one default). Distinct slug dirs.
run "https://github.com/a/one|main https://github.com/b/two|"
check "round1: a/one cloned"        present github.com-a-one
check "round1: b/two cloned"        present github.com-b-two

# Round 2: only a/one still linked -> b/two pruned, a/one kept.
run "https://github.com/a/one|main"
check "round2: a/one kept"          present github.com-a-one
check "round2: b/two pruned"        bash -c "[ ! -e '$WS/repos/github.com-b-two' ]"

# Same-basename repos on different owners must not collide (slug is full path).
run "https://github.com/x/dup|main https://github.com/y/dup|main"
check "round3: x/dup cloned"        present github.com-x-dup
check "round3: y/dup cloned"        present github.com-y-dup
check "round3: a/one pruned"        bash -c "[ ! -e '$WS/repos/github.com-a-one' ]"

# Nothing linked, repos dir exists -> everything pruned.
run ""
check "round4: all pruned"          bash -c "[ -z \"\$(ls -A '$WS/repos')\" ]"

# No EXTRA_REPOS and no repos dir -> clean exit 0, no dir created.
rm -rf "$WS/repos"
check "round5: clean exit"          bash -c "EXTRA_REPOS='' '$SCRIPT' test '$WS'"
check "round5: no repos dir made"   bash -c "[ ! -d '$WS/repos' ]"

if [ "$fails" -ne 0 ]; then
  echo "==> test-reconcile: ${fails} check(s) failed" >&2
  exit 1
fi
echo "==> test-reconcile: all checks passed"
