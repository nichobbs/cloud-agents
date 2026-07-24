#!/usr/bin/env bash
# Regression test for docker/render-branch-policy.sh (the branch-policy
# rendering logic extracted from inject-library.sh, #732). Exercises the
# REAL function against temp workspaces.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/docker/render-branch-policy.sh"
[ -f "$HELPER" ] || { echo "test-branch-policy-inject: $HELPER not found" >&2; exit 1; }

# Source the helper to get render_branch_policy in scope
source "$HELPER"

# Use the source file directly when not inside a built container
BRANCH_POLICY_SRC="${BRANCH_POLICY_SRC:-/etc/cloud-agents/branch-policy-rules.md}"
if [ ! -f "$BRANCH_POLICY_SRC" ]; then
    BRANCH_POLICY_SRC="$REPO_ROOT/docker/branch-policy-rules.md"
    [ -f "$BRANCH_POLICY_SRC" ] || { echo "test-branch-policy-inject: branch-policy-rules.md not found" >&2; exit 1; }
fi
export BRANCH_POLICY_SRC

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

# ── Claude: should write .claude/rules/branch-policy.md ──────────────────────
WS="$(mktemp -d)"
mkdir -p "$WS/.claude"
render_branch_policy "claude" "$WS"
check "claude: branch-policy.md created"  test -f "$WS/.claude/rules/branch-policy.md"
check "claude: content matches source"    diff -q "$BRANCH_POLICY_SRC" "$WS/.claude/rules/branch-policy.md" >/dev/null 2>&1
rm -rf "$WS"

# ── OpenCode: should write .cloud-agents/branch-policy.md + update opencode.json ──
WS="$(mktemp -d)"
cat > "$WS/opencode.json" <<'EOF'
{"instructions": ["AGENTS.md"]}
EOF
render_branch_policy "opencode" "$WS"
check "opencode: branch-policy.md created"    test -f "$WS/.cloud-agents/branch-policy.md"
check "opencode: content matches source"      diff -q "$BRANCH_POLICY_SRC" "$WS/.cloud-agents/branch-policy.md" >/dev/null 2>&1
check "opencode: opencode.json updated"       grep -q "branch-policy.md" "$WS/opencode.json"
rm -rf "$WS"

# ── Gemini: should write GEMINI.md when absent ───────────────────────────────
WS="$(mktemp -d)"
render_branch_policy "gemini" "$WS"
check "gemini: GEMINI.md created"         test -f "$WS/GEMINI.md"
check "gemini: content matches source"    diff -q "$BRANCH_POLICY_SRC" "$WS/GEMINI.md" >/dev/null 2>&1
rm -rf "$WS"

# ── Gemini: should NOT clobber existing GEMINI.md ────────────────────────────
WS="$(mktemp -d)"
echo "# My custom GEMINI.md" > "$WS/GEMINI.md"
ORIGINAL=$(cat "$WS/GEMINI.md")
render_branch_policy "gemini" "$WS"
NEW=$(cat "$WS/GEMINI.md")
check "gemini: existing GEMINI.md preserved"  bash -c "[ \"$ORIGINAL\" = \"$NEW\" ]"
rm -rf "$WS"

# ── Codex: should NOT write any branch-policy file ───────────────────────────
WS="$(mktemp -d)"
mkdir -p "$WS/.claude"
render_branch_policy "codex" "$WS"
check "codex: no .claude/rules/branch-policy.md"  bash -c "[ ! -f '$WS/.claude/rules/branch-policy.md' ]"
check "codex: no .cloud-agents/branch-policy.md"   bash -c "[ ! -f '$WS/.cloud-agents/branch-policy.md' ]"
check "codex: no GEMINI.md"                        bash -c "[ ! -f '$WS/GEMINI.md' ]"
rm -rf "$WS"

if [ "$fails" -ne 0 ]; then
  echo "==> test-branch-policy-inject: ${fails} check(s) failed" >&2
  exit 1
fi
echo "==> test-branch-policy-inject: all checks passed"
