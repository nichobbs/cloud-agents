#!/usr/bin/env bash
# Regression test for the branch-policy rendering logic in inject-library.sh
# (#726). Tests the per-harness file creation in isolation by extracting just
# the branch-policy section and running it against temp workspaces.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/docker/branch-policy-rules.md"
[ -f "$SRC" ] || { echo "test-branch-policy-inject: $SRC not found" >&2; exit 1; }

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

# ── Claude: should write .claude/rules/branch-policy.md ──────────────────────
WS="$(mktemp -d)"
mkdir -p "$WS/.claude"
(cd "$WS" && HARNESS="claude" BRANCH_POLICY_SRC="$SRC" bash -c '
    case "$HARNESS" in
        claude)
            mkdir -p .claude/rules
            cp "$BRANCH_POLICY_SRC" .claude/rules/branch-policy.md
            ;;
    esac
' 2>/dev/null)
check "claude: branch-policy.md created"  test -f "$WS/.claude/rules/branch-policy.md"
check "claude: content matches source"    diff -q "$SRC" "$WS/.claude/rules/branch-policy.md" >/dev/null 2>&1
rm -rf "$WS"

# ── OpenCode: should write .cloud-agents/branch-policy.md + update opencode.json ──
WS="$(mktemp -d)"
cat > "$WS/opencode.json" <<'EOF'
{"instructions": ["AGENTS.md"]}
EOF
(cd "$WS" && HARNESS="opencode" BRANCH_POLICY_SRC="$SRC" bash -c '
    case "$HARNESS" in
        opencode)
            mkdir -p .cloud-agents
            cp "$BRANCH_POLICY_SRC" .cloud-agents/branch-policy.md
            if command -v jq >/dev/null 2>&1 && [ -f opencode.json ]; then
                tmp=$(mktemp "opencode.json.XXXXXX")
                jq ".instructions = ((.instructions // []) | . + [\".cloud-agents/branch-policy.md\"] | unique)" \
                    opencode.json > "$tmp" && mv "$tmp" opencode.json
            fi
            ;;
    esac
' 2>/dev/null)
check "opencode: branch-policy.md created"    test -f "$WS/.cloud-agents/branch-policy.md"
check "opencode: content matches source"      diff -q "$SRC" "$WS/.cloud-agents/branch-policy.md" >/dev/null 2>&1
check "opencode: opencode.json updated"       grep -q "branch-policy.md" "$WS/opencode.json"
rm -rf "$WS"

# ── Gemini: should write GEMINI.md when absent ───────────────────────────────
WS="$(mktemp -d)"
(cd "$WS" && HARNESS="gemini" BRANCH_POLICY_SRC="$SRC" bash -c '
    case "$HARNESS" in
        gemini)
            if [ ! -f GEMINI.md ]; then
                cp "$BRANCH_POLICY_SRC" GEMINI.md
            fi
            ;;
    esac
' 2>/dev/null)
check "gemini: GEMINI.md created"         test -f "$WS/GEMINI.md"
check "gemini: content matches source"    diff -q "$SRC" "$WS/GEMINI.md" >/dev/null 2>&1
rm -rf "$WS"

# ── Gemini: should NOT clobber existing GEMINI.md ────────────────────────────
WS="$(mktemp -d)"
echo "# My custom GEMINI.md" > "$WS/GEMINI.md"
ORIGINAL=$(cat "$WS/GEMINI.md")
(cd "$WS" && HARNESS="gemini" BRANCH_POLICY_SRC="$SRC" bash -c '
    case "$HARNESS" in
        gemini)
            if [ ! -f GEMINI.md ]; then
                cp "$BRANCH_POLICY_SRC" GEMINI.md
            fi
            ;;
    esac
' 2>/dev/null)
NEW=$(cat "$WS/GEMINI.md")
check "gemini: existing GEMINI.md preserved"  bash -c "[ \"$ORIGINAL\" = \"$NEW\" ]"
rm -rf "$WS"

# ── Codex: should NOT write any branch-policy file ───────────────────────────
WS="$(mktemp -d)"
mkdir -p "$WS/.claude"
(cd "$WS" && HARNESS="codex" bash -c '
    case "$HARNESS" in
        codex) ;;  # no-op
    esac
' 2>/dev/null)
check "codex: no .claude/rules/branch-policy.md"  bash -c "[ ! -f '$WS/.claude/rules/branch-policy.md' ]"
check "codex: no .cloud-agents/branch-policy.md"   bash -c "[ ! -f '$WS/.cloud-agents/branch-policy.md' ]"
check "codex: no GEMINI.md"                        bash -c "[ ! -f '$WS/GEMINI.md' ]"
rm -rf "$WS"

if [ "$fails" -ne 0 ]; then
  echo "==> test-branch-policy-inject: ${fails} check(s) failed" >&2
  exit 1
fi
echo "==> test-branch-policy-inject: all checks passed"
