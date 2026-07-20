#!/bin/bash
# Runner entrypoint for a single Claude Code invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - Claude model to use (default: claude-opus-4-8)
#   NATIVE_SESSION_ID - session ID to resume; if non-empty passed to --resume
#   GITHUB_TOKEN      - PAT injected into the GitHub MCP server (Phase 4, optional)
#   CLOUD_AGENTS_MCP_CALLBACKS  - "0" to disable the Phase 6 MCP-callback shim
#                                 (docs/phase6-mcp-callbacks.md); on by
#                                 default as of stage 4 (§8). Mirrors
#                                 CloudAgents.NetworkPolicy.callbacksFeatureEnabled's
#                                 on-unless-"0" default — keep the two in
#                                 sync. Registering the shim's MCP-server
#                                 entry below is additionally guarded on the
#                                 template file actually existing in this
#                                 image, so an image built before stage 3
#                                 shipped the shim still runs fine with the
#                                 flag on.
#   CLOUD_AGENTS_API_URL        - host API base URL, as reachable from this
#                                 container (only used when the flag above is
#                                 set; minted by CloudAgents.Docker)
#   CLOUD_AGENTS_CALLBACK_TOKEN - per-session callback bearer token (ditto)
#
# State persists across runs via two mounted volumes:
#   /workspace            - the cloned repository + .claude session files
#   /home/claude-user     - the user's authenticated ~/.claude credentials
#
# Each container handles exactly one prompt and then exits; --resume reads the
# conversation history from the workspace so context survives.

set -euo pipefail

BRANCH="${BRANCH:-main}"
MODEL="${MODEL:-claude-opus-4-8}"
NATIVE_SESSION_ID="${NATIVE_SESSION_ID:-}"
# Default-on unless explicitly "0" — mirrors
# CloudAgents.NetworkPolicy.callbacksFeatureEnabled()'s Lyric-side default
# (docs/phase6 §8). Deliberately NOT "${CLOUD_AGENTS_MCP_CALLBACKS:-1}": that
# form only substitutes when the var is unset/empty, which happens to give
# the same on-unless-"0" result for every value the var actually takes, but
# spells out the "off-unless-1" default this stage replaced — normalizing
# through the explicit comparison below keeps the intent obvious and matches
# the Lyric side's `!= "0"` check byte-for-byte.
if [ "${CLOUD_AGENTS_MCP_CALLBACKS:-}" = "0" ]; then
    CLOUD_AGENTS_MCP_CALLBACKS="0"
else
    CLOUD_AGENTS_MCP_CALLBACKS="1"
fi

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint: PROMPT is required" >&2
    exit 64
fi

# Restore a Claude subscription (OAuth) login from the vault on a fresh home
# volume. A subscription login is a ~/.claude directory, not an API key, so it
# ships as a base64 tar.gz in the CLAUDE_HOME_TARBALL_B64 credential (see
# scripts/upload-credentials.sh --claude-home). Unpack it only when the
# persisted home volume has no credentials yet, so an existing — possibly
# token-refreshed — login is never overwritten. The blob is never echoed.
: "${HOME:=/home/claude-user}"
if [ -n "${CLAUDE_HOME_TARBALL_B64:-}" ] && [ ! -f "$HOME/.claude/.credentials.json" ]; then
    echo "entrypoint: restoring ~/.claude auth from the vault bundle" >&2
    mkdir -p "$HOME/.claude"
    printf '%s' "${CLAUDE_HOME_TARBALL_B64}" | base64 -d | tar -xzf - -C "$HOME/.claude"
fi

# Clone the repository on first run; reuse the volume afterwards.
if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all four harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint"
cd /workspace
mkdir -p /workspace/.claude

# Phase 4: render the GitHub MCP server config and safe auto-approvals from the
# templates baked into the image, substituting the injected token. The token
# lands inside a JSON string in mcp.json, and — now that arbitrary secrets flow
# through the credential store, and GITHUB_TOKEN is not a reserved credential
# name — its value can contain any byte. Escape in two stages so neither the
# JSON nor the sed substitution is corrupted:
#   0. strip C0 control bytes (0x00-0x1F) — a JSON string may not contain a raw
#      newline/tab/etc., so a token carrying one would otherwise produce invalid
#      JSON (#222). A real GITHUB_TOKEN never contains control bytes, so this is
#      a no-op for valid input and fails safe (a cleaned, then-invalid token
#      simply fails auth) for malformed input.
#   1. JSON-escape the value ('\' then '"') so it is a valid JSON string body.
#   2. sed-escape the result ('&', '|', '\') so sed writes it literally.
# Order matters: JSON-escaping adds backslashes that stage 2 must then protect.
if [ -f /etc/claude/mcp.json.template ] && [ ! -f /workspace/.claude/mcp.json ]; then
    gh_token_clean=$(printf '%s' "${GITHUB_TOKEN:-}" | tr -d '\000-\037')
    gh_token_json=$(printf '%s' "${gh_token_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    gh_token_escaped=$(printf '%s' "${gh_token_json}" | sed -e 's/[&|\\]/\\&/g')
    sed "s|\${GITHUB_TOKEN}|${gh_token_escaped}|g" \
        /etc/claude/mcp.json.template > /workspace/.claude/mcp.json

    # Phase 6 (docs/phase6-mcp-callbacks.md): register the cloud-agents MCP
    # server so the agent can request permission decisions / ask the human a
    # question / report progress mid-run. On by default as of stage 4 (§8);
    # gated behind CLOUD_AGENTS_MCP_CALLBACKS (opt out with =0), the
    # mcp-callbacks.json.template file actually existing in this image
    # (without this guard, an image built before stage 3 shipped the shim
    # would have `claude` try to spawn a nonexistent command on every run),
    # AND a non-empty CLOUD_AGENTS_CALLBACK_TOKEN — docker_manager.l mints
    # the token best-effort and simply omits both callback env vars on
    # failure (§8: "the entrypoint's existing guards keep runs working when
    # no token was minted"), and cloud-agents-shim's main.l panics at
    # startup on a missing required env var, so registering the server
    # without a token would only ever produce a broken MCP server entry.
    # jq merges the base mcp.json with the rendered callbacks fragment so
    # both server entries coexist regardless of future additions to either
    # template.
    if [ "${CLOUD_AGENTS_MCP_CALLBACKS}" = "1" ] && [ -f /etc/claude/mcp-callbacks.json.template ] && [ -n "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" ] && command -v jq >/dev/null 2>&1; then
        api_url_clean=$(printf '%s' "${CLOUD_AGENTS_API_URL:-}" | tr -d '\000-\037')
        api_url_json=$(printf '%s' "${api_url_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        api_url_escaped=$(printf '%s' "${api_url_json}" | sed -e 's/[&|\\]/\\&/g')
        token_clean=$(printf '%s' "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" | tr -d '\000-\037')
        token_json=$(printf '%s' "${token_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        token_escaped=$(printf '%s' "${token_json}" | sed -e 's/[&|\\]/\\&/g')
        session_id_clean=$(printf '%s' "${NATIVE_SESSION_ID}" | tr -d '\000-\037')
        session_id_json=$(printf '%s' "${session_id_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        session_id_escaped=$(printf '%s' "${session_id_json}" | sed -e 's/[&|\\]/\\&/g')
        # Optional timeout override (docs/phase6 §2, #533): MCP servers only
        # receive env vars listed in mcp.json, so the container-level value
        # must be re-listed here. Unset renders as "" and the shim falls
        # back to its default.
        timeout_ms_clean=$(printf '%s' "${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS:-}" | tr -d '\000-\037')
        timeout_ms_json=$(printf '%s' "${timeout_ms_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        timeout_ms_escaped=$(printf '%s' "${timeout_ms_json}" | sed -e 's/[&|\\]/\\&/g')
        callbacks_fragment=$(sed \
            -e "s|\${CLOUD_AGENTS_API_URL}|${api_url_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_CALLBACK_TOKEN}|${token_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_SESSION_ID}|${session_id_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS}|${timeout_ms_escaped}|g" \
            /etc/claude/mcp-callbacks.json.template)
        merged=$(jq -s '.[0].mcpServers += .[1].mcpServers | .[0]' \
            /workspace/.claude/mcp.json <(printf '%s' "${callbacks_fragment}"))
        printf '%s' "${merged}" > /workspace/.claude/mcp.json
    fi
fi
# Phase 6 (docs/phase6-mcp-callbacks.md §8): whether request_permission is
# actually live for THIS run — the flag is on AND a callback token was minted
# (mint is best-effort; docker_manager.l). This is the SAME condition that
# gates the mcp.json registration and --permission-prompt-tool below, computed
# once here so the settings allowlist and the prompt tool can never disagree.
CALLBACKS_ACTIVE=0
if [ "${CLOUD_AGENTS_MCP_CALLBACKS}" = "1" ] && [ -n "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" ]; then
    CALLBACKS_ACTIVE=1
fi

# Choose the static settings.json allowlist by whether callbacks are live:
#   - callbacks active  -> the tight read-only set (settings-callbacks.json.template:
#     Read/Glob/Grep); everything else routes through --permission-prompt-tool,
#     which pauses for a human decision.
#   - callbacks inactive -> the broader pre-Phase-6 set (settings.json.template:
#     Read + Bash(git:*)). With no prompt tool wired this run, tightening the
#     allowlist would fail those tool calls closed with no recourse — so the
#     tightening MUST be gated on callbacks being active (#543).
# NOTE: both templates must stay strict, comment-free JSON — CI validates them
# with `python3 -m json.tool` (.github/workflows/ci.yml "Validate JSON
# templates"), which rejects JSON5/JSONC comments; this rationale lives here.
if [ ! -f /workspace/.claude/settings.json ]; then
    if [ "${CALLBACKS_ACTIVE}" = "1" ] && [ -f /etc/claude/settings-callbacks.json.template ]; then
        cp /etc/claude/settings-callbacks.json.template /workspace/.claude/settings.json
    elif [ -f /etc/claude/settings.json.template ]; then
        cp /etc/claude/settings.json.template /workspace/.claude/settings.json
    fi
fi

# Very first invocation? Seed the session so --resume has history to attach to.
if [ ! -f /workspace/.claude/history.jsonl ]; then
    claude -p "Initialise session" --model "${MODEL}" --resume || true
fi

# Phase 6 (docs/phase6-mcp-callbacks.md §3, §8): route Claude Code's own
# permission prompts through the cloud-agents MCP server instead of the
# static settings.json allowlist, so a tool call outside that allowlist pauses
# for a human decision instead of failing closed. On by default as of stage 4.
# Gated on the SAME condition as the mcp.json registration above (flag on AND
# a token for THIS run) rather than just the flag: pointing
# --permission-prompt-tool at an MCP server entry that was never actually
# registered (no token minted this run — mint is best-effort, see
# docker_manager.l) would make Claude Code route every permission decision
# through a tool that can't answer, instead of the pre-Phase-6 behavior this
# run must fall back to. An empty array is a no-op either way.
PERMISSION_PROMPT_ARGS=()
if [ "${CALLBACKS_ACTIVE}" = "1" ]; then
    PERMISSION_PROMPT_ARGS=(--permission-prompt-tool "mcp__cloud-agents__request_permission")
fi

# Run the actual prompt. stdout is captured by the API server and streamed to
# the browser as SSE. Resume a specific session if NATIVE_SESSION_ID is set;
# otherwise resume the most recent session in the workspace volume.
if [ -n "$NATIVE_SESSION_ID" ]; then
    exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${NATIVE_SESSION_ID}" "${PERMISSION_PROMPT_ARGS[@]}"
else
    exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${PERMISSION_PROMPT_ARGS[@]}"
fi
