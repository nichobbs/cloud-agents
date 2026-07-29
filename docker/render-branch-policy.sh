#!/bin/bash
# docker/render-branch-policy.sh — renders the branch-policy rules file into
# the harness's native config location. Extracted from inject-library.sh so
# both the real script and tests can exercise the same code (#732).
#
# Usage: source this file, then call render_branch_policy <harness> [workspace-root]
# Or:    render_branch_policy <harness> [workspace-root]
#
# Reads BRANCH_POLICY_SRC from the environment (default: /etc/cloud-agents/branch-policy-rules.md).
set -euo pipefail

render_branch_policy() {
    local harness="${1:?render_branch_policy: harness required}"
    local ws="${2:-.}"
    local src="${BRANCH_POLICY_SRC:-/etc/cloud-agents/branch-policy-rules.md}"

    [ -f "$src" ] || return 0

    case "$harness" in
        claude)
            mkdir -p "$ws/.claude/rules"
            cp "$src" "$ws/.claude/rules/branch-policy.md"
            ;;
        opencode)
            mkdir -p "$ws/.cloud-agents"
            cp "$src" "$ws/.cloud-agents/branch-policy.md"
            if command -v jq >/dev/null 2>&1 && [ -f "$ws/opencode.json" ]; then
                tmp=$(mktemp "$ws/opencode.json.XXXXXX")
                jq '.instructions = ((.instructions // []) | . + [".cloud-agents/branch-policy.md"] | unique)' \
                    "$ws/opencode.json" > "$tmp" && mv "$tmp" "$ws/opencode.json"
            fi
            ;;
        gemini)
            # Only write if the repo doesn't already have one (user-authored takes precedence).
            if [ ! -f "$ws/GEMINI.md" ]; then
                cp "$src" "$ws/GEMINI.md"
            fi
            ;;
        codex)
            # Codex only reads AGENTS.md / AGENTS.override.md from the git root;
            # adding a separate file would override the user's AGENTS.md. The
            # branch instruction is injected via prompt prefix in
            # entrypoint-codex.sh instead.
            ;;
    esac
}
