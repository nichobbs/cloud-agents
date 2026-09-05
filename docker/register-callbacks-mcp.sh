#!/bin/bash
# docker/register-callbacks-mcp.sh — registers the cloud-agents MCP callback
# shim (cloud-agents-shim, docs/phase6-mcp-callbacks.md) in a NON-CLAUDE
# harness's native MCP config, so opencode/codex/gemini/antigravity get the same
# add_todo/update_todo/report_progress/... tools the claude harness has had
# since Phase 6. The claude harness keeps its own, more involved
# reconciliation in entrypoint.sh (its registration is coupled to the
# --permission-prompt-tool contract); this script deliberately covers only
# the other four (entrypoint.sh does source it for exclude_from_git, #792).
#
# Reconciled EVERY message, mirroring entrypoint.sh's #548 semantics: the
# entry is added/refreshed when callbacks are live for this run (flag on,
# token minted, shim binary present) and stripped when not, so a transient
# mint failure can't leave a stale registration pointing at a dead token.
# The strip path only rewrites a file that actually carries our entry
# (#812) — a user's config is never reformatted just to delete an absent
# key. All JSON is built with jq --arg (never sed templating), so a
# token/URL containing JSON metacharacters can't corrupt the config.
#
# Usage: source this file, then call register_callbacks_mcp <harness> [workspace-root]
#        harness: opencode | codex | gemini | antigravity
set -euo pipefail

# Whether callbacks are live for THIS run: default-on flag (off only on the
# explicit "0", matching CloudAgents.NetworkPolicy.callbacksFeatureEnabled),
# a minted per-session token, and the shim actually installed in this image.
callbacks_mcp_active() {
    [ "${CLOUD_AGENTS_MCP_CALLBACKS:-}" != "0" ] \
        && [ -n "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" ] \
        && command -v cloud-agents-shim >/dev/null 2>&1
}

# Adds `path` (workspace-root-relative) to the repo's git exclude file so
# the token-bearing config this script writes can't ride along on an
# agent's `git add .` and leak the callback token into a commit (#788).
# Called ONLY when a token-bearing entry was actually written (#813), so a
# repo where callbacks are off (or the file is user-owned) never collects
# exclusions that could surprise someone later wanting to commit the file.
# Resolves the real git dir via rev-parse (#823) — `.git` can be a FILE
# (worktree/submodule gitfile), so a plain `.git/info` path isn't reliable —
# and specifically the COMMON dir (#828): git consults
# $GIT_COMMON_DIR/info/exclude, not a worktree's private gitdir, so writing
# to `--git-dir` in a worktree checkout would be silently ignored.
# Idempotent; a non-repo workspace is a no-op.
exclude_from_git() {
    local ws="$1" path="$2"
    local gitdir
    gitdir=$(git -C "$ws" rev-parse --git-common-dir 2>/dev/null) || return 0
    case "$gitdir" in
        /*) ;;
        *) gitdir="$ws/$gitdir" ;;
    esac
    mkdir -p "$gitdir/info"
    grep -qxF "/$path" "$gitdir/info/exclude" 2>/dev/null \
        || printf '/%s\n' "$path" >> "$gitdir/info/exclude"
}

# Whether workspace-relative `path` is a git-TRACKED file (#799). Exclusion
# only protects untracked paths — writing the live callback token into a
# repo-COMMITTED opencode.json/.codex/config.toml would put it straight
# into the next agent commit's diff. A tracked target demotes the
# registration to the strip path (tools unavailable for that harness in
# that repo, with a stderr note) rather than ever writing the token.
# Delegates entirely to git (#823 — works for gitfile checkouts too); a
# non-repo workspace reports untracked.
is_git_tracked() {
    local ws="$1" path="$2"
    git -C "$ws" ls-files --error-unmatch -- "$path" >/dev/null 2>&1
}

# Run `"$@" > tmp` and mv into place only on success; on failure remove the
# temp file (#802) and say so on stderr (#811) — a swallowed jq/awk failure
# would otherwise leave the registration silently stale.
apply_to_file() {
    local file="$1"
    shift
    local tmp
    tmp=$(mktemp "${file}.XXXXXX")
    if "$@" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        echo "register-callbacks-mcp: failed to update $file, leaving it unchanged" >&2
        return 1
    fi
}

register_callbacks_mcp() {
    local harness="${1:?register_callbacks_mcp: harness required}"
    local ws="${2:-.}"

    local active=0
    if callbacks_mcp_active; then
        active=1
    fi

    case "$harness" in
        opencode)
            command -v jq >/dev/null 2>&1 || return 0
            local file="$ws/opencode.json"
            [ -f "$file" ] || printf '{}' > "$file"
            # Excluded from git unconditionally (#1045), whether or not
            # callbacks are active this run: this is the same file that
            # carries the live callback token when they ARE active, so an
            # agent's `git add -A && git push` with callbacks off must not
            # be able to catch a token a LATER message writes here. Matches
            # entrypoint.sh's unconditional treatment of .claude/mcp.json.
            exclude_from_git "$ws" "opencode.json"
            local write="$active"
            if [ "$write" = "1" ] && is_git_tracked "$ws" "opencode.json"; then
                echo "register-callbacks-mcp: opencode.json is git-tracked in this repo; refusing to write the callback token into it (cloud-agents tools unavailable for this harness here)" >&2
                write=0
            fi
            if [ "$write" = "1" ]; then
                # OpenCode's local-MCP shape (type/command-array/environment)
                # per its current config schema — distinct from
                # inject-library.sh's generic {command,args,env} guess for
                # library-granted servers.
                apply_to_file "$file" jq \
                   --arg url "${CLOUD_AGENTS_API_URL:-}" \
                   --arg tok "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" \
                   --arg sid "${SESSION_ID:-}" \
                   --arg to "${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS:-}" \
                   '.mcp["cloud-agents"] = {
                      type: "local",
                      command: ["cloud-agents-shim"],
                      enabled: true,
                      environment: {
                        CLOUD_AGENTS_API_URL: $url,
                        CLOUD_AGENTS_CALLBACK_TOKEN: $tok,
                        CLOUD_AGENTS_SESSION_ID: $sid,
                        CLOUD_AGENTS_CALLBACK_TIMEOUT_MS: $to
                      }
                    }' "$file"
            elif jq -e '.mcp["cloud-agents"]' "$file" >/dev/null 2>&1; then
                apply_to_file "$file" jq 'del(.mcp["cloud-agents"])' "$file"
            fi
            ;;
        gemini|antigravity)
            command -v jq >/dev/null 2>&1 || return 0
            local file="$ws/.gemini/settings.json"
            mkdir -p "$ws/.gemini"
            [ -f "$file" ] || printf '{}' > "$file"
            # Excluded from git unconditionally (#1045) — see the opencode
            # case above for why this can't wait for callbacks to be active.
            exclude_from_git "$ws" ".gemini/settings.json"
            local write="$active"
            if [ "$write" = "1" ] && is_git_tracked "$ws" ".gemini/settings.json"; then
                echo "register-callbacks-mcp: .gemini/settings.json is git-tracked in this repo; refusing to write the callback token into it (cloud-agents tools unavailable for this harness here)" >&2
                write=0
            fi
            if [ "$write" = "1" ]; then
                apply_to_file "$file" jq \
                   --arg url "${CLOUD_AGENTS_API_URL:-}" \
                   --arg tok "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" \
                   --arg sid "${SESSION_ID:-}" \
                   --arg to "${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS:-}" \
                   '.mcpServers["cloud-agents"] = {
                      command: "cloud-agents-shim",
                      env: {
                        CLOUD_AGENTS_API_URL: $url,
                        CLOUD_AGENTS_CALLBACK_TOKEN: $tok,
                        CLOUD_AGENTS_SESSION_ID: $sid,
                        CLOUD_AGENTS_CALLBACK_TIMEOUT_MS: $to
                      }
                    }' "$file"
            elif jq -e '.mcpServers["cloud-agents"]' "$file" >/dev/null 2>&1; then
                apply_to_file "$file" jq 'del(.mcpServers["cloud-agents"])' "$file"
            fi
            ;;
        codex)
            # TOML — a marker-delimited block, stripped and re-rendered every
            # run, exactly like inject-library.sh's render_mcp_codex. Values
            # are TOML-escaped via jq's @json (a JSON string literal is also
            # a valid TOML basic string). Codex discovers this file because
            # entrypoint-codex.sh points CODEX_HOME at /workspace/.codex
            # (#808).
            command -v jq >/dev/null 2>&1 || return 0
            local file="$ws/.codex/config.toml"
            local begin="# BEGIN cloud-agents-callbacks-mcp (managed by cloud-agents; do not edit)"
            local end="# END cloud-agents-callbacks-mcp"
            mkdir -p "$ws/.codex"
            [ -f "$file" ] || : > "$file"
            # Excluded from git unconditionally (#1045) — see the opencode
            # case above for why this can't wait for callbacks to be active.
            exclude_from_git "$ws" ".codex/config.toml"
            local write="$active"
            if [ "$write" = "1" ] && is_git_tracked "$ws" ".codex/config.toml"; then
                echo "register-callbacks-mcp: .codex/config.toml is git-tracked in this repo; refusing to write the callback token into it (cloud-agents tools unavailable for this harness here)" >&2
                write=0
            fi
            # Strip any existing block — but only touch the file when the
            # marker is actually present (#812) or we're about to append. A
            # FAILED strip bails before the append (#829): appending on top
            # of a still-present old block would leave two
            # [mcp_servers.cloud-agents] tables, which is invalid TOML.
            if grep -qF "$begin" "$file"; then
                apply_to_file "$file" awk -v b="$begin" -v e="$end" '
                    $0 == b {skip = 1; next}
                    $0 == e {skip = 0; next}
                    skip != 1 {print}
                ' "$file" || return 1
            fi
            if [ "$write" = "1" ]; then
                {
                    printf '%s\n' "$begin"
                    printf '[mcp_servers.cloud-agents]\n'
                    printf 'command = %s\n' "$(jq -n --arg v "cloud-agents-shim" '$v | @json' -r)"
                    printf 'env = { "CLOUD_AGENTS_API_URL" = %s, "CLOUD_AGENTS_CALLBACK_TOKEN" = %s, "CLOUD_AGENTS_SESSION_ID" = %s, "CLOUD_AGENTS_CALLBACK_TIMEOUT_MS" = %s }\n' \
                        "$(jq -n --arg v "${CLOUD_AGENTS_API_URL:-}" '$v | @json' -r)" \
                        "$(jq -n --arg v "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" '$v | @json' -r)" \
                        "$(jq -n --arg v "${SESSION_ID:-}" '$v | @json' -r)" \
                        "$(jq -n --arg v "${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS:-}" '$v | @json' -r)"
                    printf '%s\n' "$end"
                } >> "$file"
            fi
            ;;
        *)
            echo "register-callbacks-mcp: unknown harness '$harness', skipping" >&2
            ;;
    esac
}
