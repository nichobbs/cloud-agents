#!/bin/bash
# docker/register-callbacks-mcp.sh — registers the cloud-agents MCP callback
# shim (cloud-agents-shim, docs/phase6-mcp-callbacks.md) in a NON-CLAUDE
# harness's native MCP config, so opencode/codex/gemini get the same
# add_todo/update_todo/report_progress/... tools the claude harness has had
# since Phase 6. The claude harness keeps its own, more involved
# reconciliation in entrypoint.sh (its registration is coupled to the
# --permission-prompt-tool contract); this script deliberately covers only
# the other three.
#
# Reconciled EVERY message, mirroring entrypoint.sh's #548 semantics: the
# entry is added/refreshed when callbacks are live for this run (flag on,
# token minted, shim binary present) and stripped when not, so a transient
# mint failure can't leave a stale registration pointing at a dead token.
# All JSON is built with jq --arg (never sed templating), so a token/URL
# containing JSON metacharacters can't corrupt the config.
#
# Usage: source this file, then call register_callbacks_mcp <harness> [workspace-root]
#        harness: opencode | codex | gemini
set -euo pipefail

# Whether callbacks are live for THIS run: default-on flag (off only on the
# explicit "0", matching CloudAgents.NetworkPolicy.callbacksFeatureEnabled),
# a minted per-session token, and the shim actually installed in this image.
callbacks_mcp_active() {
    [ "${CLOUD_AGENTS_MCP_CALLBACKS:-}" != "0" ] \
        && [ -n "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" ] \
        && command -v cloud-agents-shim >/dev/null 2>&1
}

# Adds `path` (workspace-root-relative) to .git/info/exclude so the
# token-bearing config this script writes can't ride along on an agent's
# `git add .` and leak the callback token into a commit (#788). Git
# excludes only apply to UNTRACKED paths, so a repo that deliberately
# commits its own opencode.json/.codex/config.toml is unaffected — this
# only stops the file WE created from being staged accidentally.
# Idempotent; a workspace without .git is a no-op.
exclude_from_git() {
    local ws="$1" path="$2"
    [ -d "$ws/.git" ] || return 0
    mkdir -p "$ws/.git/info"
    grep -qxF "/$path" "$ws/.git/info/exclude" 2>/dev/null \
        || printf '/%s\n' "$path" >> "$ws/.git/info/exclude"
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
            exclude_from_git "$ws" "opencode.json"
            local tmp
            tmp=$(mktemp "${file}.XXXXXX")
            if [ "$active" = "1" ]; then
                # OpenCode's local-MCP shape (type/command-array/environment)
                # per its current config schema — distinct from
                # inject-library.sh's generic {command,args,env} guess for
                # library-granted servers.
                jq --arg url "${CLOUD_AGENTS_API_URL:-}" \
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
                    }' "$file" > "$tmp" && mv "$tmp" "$file"
            else
                jq 'if (.mcp | type) == "object" then del(.mcp["cloud-agents"]) else . end' \
                    "$file" > "$tmp" && mv "$tmp" "$file"
            fi
            ;;
        gemini)
            command -v jq >/dev/null 2>&1 || return 0
            local file="$ws/.gemini/settings.json"
            mkdir -p "$ws/.gemini"
            [ -f "$file" ] || printf '{}' > "$file"
            exclude_from_git "$ws" ".gemini/settings.json"
            local tmp
            tmp=$(mktemp "${file}.XXXXXX")
            if [ "$active" = "1" ]; then
                jq --arg url "${CLOUD_AGENTS_API_URL:-}" \
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
                    }' "$file" > "$tmp" && mv "$tmp" "$file"
            else
                jq 'if (.mcpServers | type) == "object" then del(.mcpServers["cloud-agents"]) else . end' \
                    "$file" > "$tmp" && mv "$tmp" "$file"
            fi
            ;;
        codex)
            # TOML — a marker-delimited block, stripped and re-rendered every
            # run, exactly like inject-library.sh's render_mcp_codex. Values
            # are TOML-escaped via jq's @json (a JSON string literal is also
            # a valid TOML basic string).
            command -v jq >/dev/null 2>&1 || return 0
            local file="$ws/.codex/config.toml"
            local begin="# BEGIN cloud-agents-callbacks-mcp (managed by cloud-agents; do not edit)"
            local end="# END cloud-agents-callbacks-mcp"
            mkdir -p "$ws/.codex"
            [ -f "$file" ] || : > "$file"
            exclude_from_git "$ws" ".codex/config.toml"
            local tmp
            tmp=$(mktemp "${file}.XXXXXX")
            awk -v b="$begin" -v e="$end" '
                $0 == b {skip = 1; next}
                $0 == e {skip = 0; next}
                skip != 1 {print}
            ' "$file" > "$tmp"
            mv "$tmp" "$file"
            if [ "$active" = "1" ]; then
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
