#!/bin/bash
# docker/render-branch-policy.sh — renders the branch-policy rules file (and
# the session-tools guide) into the harness's native config location.
# Extracted from inject-library.sh so both the real script and tests can
# exercise the same code (#732).
#
# Usage: source this file, then call render_branch_policy <harness> [workspace-root]
#        and render_session_guide <harness> [workspace-root]
#
# Reads BRANCH_POLICY_SRC from the environment (default: /etc/cloud-agents/branch-policy-rules.md)
# and SESSION_GUIDE_SRC (default: /etc/cloud-agents/session-tools-guide.md).
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

# Renders docker/session-tools-guide.md (todo-list usage, progress
# reporting, session-notes conventions — see that file) the same way
# render_branch_policy renders its rules: per-harness native discovery
# locations, idempotent per message.
render_session_guide() {
    local harness="${1:?render_session_guide: harness required}"
    local ws="${2:-.}"
    local src="${SESSION_GUIDE_SRC:-/etc/cloud-agents/session-tools-guide.md}"

    [ -f "$src" ] || return 0

    case "$harness" in
        claude)
            mkdir -p "$ws/.claude/rules"
            cp "$src" "$ws/.claude/rules/session-tools.md"
            ;;
        opencode)
            mkdir -p "$ws/.cloud-agents"
            cp "$src" "$ws/.cloud-agents/session-tools.md"
            if command -v jq >/dev/null 2>&1 && [ -f "$ws/opencode.json" ]; then
                tmp=$(mktemp "$ws/opencode.json.XXXXXX")
                jq '.instructions = ((.instructions // []) | . + [".cloud-agents/session-tools.md"] | unique)' \
                    "$ws/opencode.json" > "$tmp" && mv "$tmp" "$ws/opencode.json"
            fi
            ;;
        gemini)
            # render_branch_policy owns GEMINI.md creation (only when the repo
            # has none of its own). Append the guide once, marker-guarded so
            # reconciling every message can't duplicate it — and only to a
            # GEMINI.md that starts with our own branch-policy header, never
            # to a user-authored one.
            if [ -f "$ws/GEMINI.md" ] \
                && head -1 "$ws/GEMINI.md" | grep -q '^# Branch Policy' \
                && ! grep -q '^# Session Visibility' "$ws/GEMINI.md"; then
                { printf '\n'; cat "$src"; } >> "$ws/GEMINI.md"
            fi
            ;;
        codex)
            # Same constraint as branch policy: injected via prompt prefix in
            # entrypoint-codex.sh instead of a file.
            ;;
    esac
}
