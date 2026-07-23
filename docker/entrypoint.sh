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
#   /workspace            - the cloned repository + our own mcp.json/settings.json
#                            and a NATIVE_SESSION_MARKER file (see below); this
#                            volume is per-session
#   /home/claude-user     - the user's authenticated ~/.claude credentials AND
#                            Claude Code's own conversation history
#                            (~/.claude/projects/...); this volume is shared
#                            across all of a user's sessions (per user+harness,
#                            not per session — docker_manager.l)
#
# Each container handles exactly one prompt and then exits; --resume reads the
# conversation history from ~/.claude on the home volume so context survives.

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

: "${HOME:=/home/claude-user}"

# If a host-provided CA certificate bundle is mounted at /etc/host-ca.pem,
# register it in the container's system CA trust store so that curl, git, and Node
# trust the host's SSL-intercepting proxy natively and globally.
if [ -f "/etc/host-ca.pem" ]; then
    echo "entrypoint: registering host CA certificate bundle in system store..." >&2
    cp /etc/host-ca.pem /usr/local/share/ca-certificates/host-ca.crt
    update-ca-certificates >/dev/null
fi

# Ensure /home/claude-user and everything inside it is owned by claude-user.
# This heals any permissions/UID mismatches if the volume was populated on the host
# with host-specific UIDs (e.g. 504 on Colima macOS).
chown -R claude-user:claude-user /home/claude-user || true
chmod 700 /home/claude-user || true
chown -R claude-user:claude-user /workspace || true

# If ~/.claude.json is missing, but backups exist, automatically restore the latest backup!
if [ ! -f "$HOME/.claude.json" ]; then
    LATEST_BACKUP=$(ls -t "$HOME"/.claude/backups/.claude.json.backup.* 2>/dev/null | head -n 1 || true)
    if [ -n "$LATEST_BACKUP" ]; then
        echo "entrypoint: restoring ~/.claude.json from latest backup: $LATEST_BACKUP" >&2
        cp "$LATEST_BACKUP" "$HOME/.claude.json"
        chown claude-user:claude-user "$HOME/.claude.json"
        chmod 600 "$HOME/.claude.json"
    fi
fi

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint: PROMPT is required" >&2
    exit 64
fi

# Pre-accept the workspace trust dialog. Claude Code normally asks
# interactively whether to trust a project directory before honoring
# settings.json's permissions.allow entries; this runner is always
# non-interactive (-p), so that prompt can never be answered, and every
# invocation would otherwise print "Ignoring N permissions.allow entries...
# this workspace has not been trusted" and fall back to unconfigured
# defaults. /workspace is always this container's (and every container's)
# project directory, so trusting it here is equivalent to a human accepting
# the dialog once. Merged with jq rather than overwritten so any other keys
# already in ~/.claude.json (e.g. a restored subscription login above) survive.
#
# This trust flag is broader than just our own /workspace/.claude/settings.json
# (which we fully control and overwrite every run, below): it also governs
# whether Claude Code auto-loads other trust-gated project config it finds in
# the cloned repo itself, e.g. a repo-root .mcp.json — REPO_URL is
# user-supplied and this entrypoint does not render/overwrite that path the
# way it does /workspace/.claude/mcp.json. That's an intentional tradeoff
# here, not an oversight: this container IS the sandbox, the same trust model
# entrypoint-gemini.sh already states explicitly for --yolo.
if command -v jq >/dev/null 2>&1; then
    base_json='{}'
    if [ -f "$HOME/.claude.json" ]; then
        base_json=$(cat "$HOME/.claude.json")
    fi
    if printf '%s' "${base_json}" | jq '.projects["/workspace"].hasTrustDialogAccepted = true' > "$HOME/.claude.json.tmp" 2>/dev/null; then
        mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
        chown claude-user:claude-user "$HOME/.claude.json"
        chmod 600 "$HOME/.claude.json"
    else
        rm -f "$HOME/.claude.json.tmp"
        echo "entrypoint: could not pre-accept the workspace trust dialog, continuing without it" >&2
    fi
fi

# Restore a Claude subscription (OAuth) login from the vault on a fresh home
# volume. A subscription login is a ~/.claude directory, not an API key, so it
# ships as a base64 tar.gz in the CLAUDE_HOME_TARBALL_B64 credential (see
# scripts/upload-credentials.sh --claude-home). Unpack it only when the
# persisted home volume has no credentials yet, so an existing — possibly
# token-refreshed — login is never overwritten. The blob is never echoed.
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

# Phase 6 (docs/phase6-mcp-callbacks.md §8): whether request_permission is
# actually live for THIS run — the flag is on AND a callback token was minted
# (mint is best-effort; docker_manager.l). Computed FIRST because it now drives
# three things that must always agree: the cloud-agents entry in mcp.json, the
# settings.json allowlist, and --permission-prompt-tool. A fresh container
# spins up per message while /workspace/.claude/{mcp.json,settings.json} persist
# across the session, so all three are reconciled every message against this
# value — a transient mint failure on one message followed by success on the
# next must not leave the persisted config disagreeing with the prompt tool
# (#548).
CALLBACKS_ACTIVE=0
if [ "${CLOUD_AGENTS_MCP_CALLBACKS}" = "1" ] && [ -n "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" ]; then
    CALLBACKS_ACTIVE=1
fi

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
fi

# Phase 6 (docs/phase6-mcp-callbacks.md §8): reconcile the cloud-agents MCP
# server entry in mcp.json EVERY message to match CALLBACKS_ACTIVE — add/refresh
# it when callbacks are live, strip any stale entry when not (#548). This must
# run outside the persist-once base render above: mcp.json survives across the
# per-message containers, so a message whose mint succeeded after a prior
# message's failure would otherwise never register the server, yet
# --permission-prompt-tool (also keyed off CALLBACKS_ACTIVE) would point at it.
# The `del` branch also cleanly removes the entry if a later message loses its
# token. Both jq ops are idempotent (verified: re-adding over an already-merged
# file and deleting an absent key are both no-ops). Requires jq; without it we
# leave mcp.json as-is and CALLBACKS_ACTIVE is forced off below so nothing
# points at an unreconciled entry.
if command -v jq >/dev/null 2>&1 && [ -f /workspace/.claude/mcp.json ]; then
    if [ "${CALLBACKS_ACTIVE}" = "1" ] && [ -f /etc/claude/mcp-callbacks.json.template ]; then
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
        merged=$(jq -s '.[0].mcpServers["cloud-agents"] = .[1].mcpServers["cloud-agents"] | .[0]' \
            /workspace/.claude/mcp.json <(printf '%s' "${callbacks_fragment}"))
        printf '%s' "${merged}" > /workspace/.claude/mcp.json
    else
        stripped=$(jq 'del(.mcpServers["cloud-agents"])' /workspace/.claude/mcp.json)
        printf '%s' "${stripped}" > /workspace/.claude/mcp.json
    fi
elif [ "${CALLBACKS_ACTIVE}" = "1" ]; then
    # jq absent (or mcp.json missing) — we cannot register/verify the callback
    # server, so force callbacks off for this run rather than wire the prompt
    # tool at an entry we could not reconcile (#548).
    CALLBACKS_ACTIVE=0
fi

# Final authority (#548): CALLBACKS_ACTIVE is derived from the ACTUAL persisted
# mcp.json, not just the preconditions above. Even after the reconcile, a
# silently-empty jq merge or an unexpected file state could leave the
# cloud-agents server absent while CALLBACKS_ACTIVE=1 — which would wire
# --permission-prompt-tool at a server that isn't there. So if callbacks are
# meant to be live but the persisted mcp.json doesn't actually contain the
# cloud-agents server entry, downgrade to inactive. From here down,
# CALLBACKS_ACTIVE == "the callback server is genuinely registered", and it is
# the single source of truth for both the settings allowlist and the prompt
# tool, so the two can never disagree.
if [ "${CALLBACKS_ACTIVE}" = "1" ]; then
    if [ ! -f /workspace/.claude/mcp.json ] || ! grep -q '"cloud-agents"' /workspace/.claude/mcp.json; then
        CALLBACKS_ACTIVE=0
    fi
fi

if [ "${CALLBACKS_ACTIVE}" = "1" ] && [ -f /etc/claude/settings-callbacks.json.template ]; then
    cp /etc/claude/settings-callbacks.json.template /workspace/.claude/settings.json
elif [ -f /etc/claude/settings.json.template ]; then
    cp /etc/claude/settings.json.template /workspace/.claude/settings.json
fi

# Render the session's profile-granted skills/subagents/MCP servers into
# Claude's own native config (docker/inject-library.sh). Reconciled every
# message like the mcp.json entries above; best-effort so a rendering hiccup
# never blocks the actual prompt run.
/usr/local/bin/inject-library.sh "claude" || echo "entrypoint: library injection failed, continuing without it" >&2

# Recursively chown the workspace after creating templates/directories as root
# so that 'claude-user' has full write access to history and configs.
chown -R claude-user:claude-user /workspace || true

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
# the browser as SSE.
#
# Whether this is the very first invocation for this native session is NOT
# determined by /workspace/.claude/history.jsonl: Claude Code never actually
# writes a file by that name. Its own conversation storage
# (~/.claude/projects/<slug>/<session-id>.jsonl) lives on the *home* volume,
# which docker_manager.l mounts per user+harness, not per session
# (docs/phase2-session-management.md "Credential Management") — so it
# persists across every session for that user, while a stale/absent check
# here made every message look like the first one. That replayed
# --session-id "${NATIVE_SESSION_ID}" on message 2+, and the CLI rejected it
# with "Session ID ... is already in use" because message 1 had already
# registered it. (Separately, the old first-invocation check also used to
# gate a broken unconditional `claude -p ... --resume` seed step with no
# session ID, which always failed with "--resume requires a valid session
# ID..." in --print mode — that's #386, fixed here by removing the seed
# step entirely, since the real invocation below already handles the
# first-run case correctly.)
#
# Track "have we already initialized this native session" ourselves instead,
# with a marker file on the workspace volume, which genuinely is
# session-scoped. Written just before exec (not after, since exec replaces
# this process and nothing after it would ever run): once --session-id has
# been sent at all, the CLI may have registered it even if the run then
# fails for an unrelated reason, so every later invocation must use --resume
# regardless of how this one turns out.
NATIVE_SESSION_MARKER=/workspace/.claude/.native-session-initialized
if [ ! -f "$NATIVE_SESSION_MARKER" ]; then
    touch "$NATIVE_SESSION_MARKER"
    chown claude-user:claude-user "$NATIVE_SESSION_MARKER" || true
    if [ -n "$NATIVE_SESSION_ID" ]; then
        exec runuser -u claude-user -- claude -p "${PROMPT}" --model "${MODEL}" --session-id "${NATIVE_SESSION_ID}" "${PERMISSION_PROMPT_ARGS[@]}"
    else
        exec runuser -u claude-user -- claude -p "${PROMPT}" --model "${MODEL}" "${PERMISSION_PROMPT_ARGS[@]}"
    fi
else
    if [ -n "$NATIVE_SESSION_ID" ]; then
        exec runuser -u claude-user -- claude -p "${PROMPT}" --model "${MODEL}" --resume "${NATIVE_SESSION_ID}" "${PERMISSION_PROMPT_ARGS[@]}"
    else
        # Depends on NATIVE_SESSION_ID always being non-empty by the time the
        # marker exists (src/handlers/sessions.l pre-assigns nativeSessionId =
        # sessionId at session creation; the DB column is NOT NULL) — a bare
        # --resume with no ID is invalid in --print mode and would reproduce
        # the exact #386 failure this file was just fixed for. Unreachable
        # today; kept only because nothing else in this branch needs it, not
        # because it's expected to fire.
        exec runuser -u claude-user -- claude -p "${PROMPT}" --model "${MODEL}" --resume "${PERMISSION_PROMPT_ARGS[@]}"
    fi
fi
