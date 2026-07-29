#!/bin/bash
# docker/inject-library.sh — renders a profile's granted skills, subagents,
# and MCP servers into HARNESS's own native config, from base64(JSON) env
# vars CloudAgents.Docker sets (CLOUD_AGENTS_SKILLS_B64 /
# CLOUD_AGENTS_SUBAGENTS_B64 / CLOUD_AGENTS_MCP_SERVERS_B64 — absent when a
# session's profile grants none of that kind). Invoked by every harness's
# entrypoint script, every message: a profile's grants can change between
# messages, and this reconciles the container's config to match — it does
# not just persist a first-run snapshot (same philosophy as entrypoint.sh's
# per-message "cloud-agents" mcp.json entry reconciliation).
#
# Every file/directory this script writes is named "cloud-agents-<name>"
# (skills/subagents) or keyed "cloud-agents-lib-<name>" (MCP servers), and a
# reconcile pass only ever removes/replaces entries under that prefix — never
# a repo-committed skill/agent file or a hand-authored MCP server entry, even
# though this script may share a directory or config file with those.
#
# Usage: inject-library.sh <harness>   # claude | codex | opencode | gemini
#
# Best-effort by design: a caller should invoke this with `|| true`-style
# tolerance (see entrypoint*.sh) so a rendering hiccup here never blocks the
# actual prompt run — library grants are an optional capability addition,
# not something the harness invocation depends on.
set -euo pipefail

HARNESS="${1:?inject-library.sh: harness argument required}"

if ! command -v jq >/dev/null 2>&1; then
    echo "inject-library.sh: jq not found, skipping library injection" >&2
    exit 0
fi

cd /workspace

case "$HARNESS" in
    claude)   SKILLS_DIR=".claude/skills";    AGENTS_DIR=".claude/agents"   ;;
    codex)    SKILLS_DIR=".agents/skills";    AGENTS_DIR=".codex/agents"    ;;
    gemini)   SKILLS_DIR=".gemini/skills";    AGENTS_DIR=".gemini/agents"   ;;
    opencode) SKILLS_DIR=".opencode/skills";  AGENTS_DIR=".opencode/agents" ;;
    *)
        echo "inject-library.sh: unknown harness '$HARNESS', skipping" >&2
        exit 0
        ;;
esac

# ── Skills ──────────────────────────────────────────────────────────────────
# SKILL.md (YAML frontmatter + markdown body) is the same format across
# Claude Code, Codex CLI, Gemini CLI, and OpenCode as of 2026 — only the
# discovery directory differs, so one render function covers all four.
# Frontmatter scalars are emitted as jq's `@json` (a double-quoted JSON
# string is also a valid YAML flow scalar), so an arbitrary user-authored
# name/description can never break the YAML even if it contains a colon,
# quote, or newline.
render_skills() {
    local dir="$1"
    mkdir -p "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 -name 'cloud-agents-*' -exec rm -rf {} + 2>/dev/null || true
    [ -n "${CLOUD_AGENTS_SKILLS_B64:-}" ] || return 0

    printf '%s' "${CLOUD_AGENTS_SKILLS_B64}" | base64 -d | jq -c '.skills[]' | while IFS= read -r item; do
        local name name_json desc_json item_dir
        name=$(jq -r '.name' <<<"$item")
        name_json=$(jq -r '.name | @json' <<<"$item")
        desc_json=$(jq -r '.description | @json' <<<"$item")
        item_dir="$dir/cloud-agents-$name"
        mkdir -p "$item_dir"
        {
            printf -- '---\n'
            printf 'name: %s\n' "$name_json"
            printf 'description: %s\n' "$desc_json"
            printf -- '---\n'
            jq -r '.body' <<<"$item"
        } > "$item_dir/SKILL.md"
    done
}

# ── Subagents: YAML-frontmatter harnesses (claude, gemini) ─────────────────
render_subagents_yaml_frontmatter() {
    local dir="$1"
    mkdir -p "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 -name 'cloud-agents-*.md' -delete 2>/dev/null || true
    [ -n "${CLOUD_AGENTS_SUBAGENTS_B64:-}" ] || return 0

    printf '%s' "${CLOUD_AGENTS_SUBAGENTS_B64}" | base64 -d | jq -c '.subagents[]' | while IFS= read -r item; do
        local name name_json desc_json model file
        name=$(jq -r '.name' <<<"$item")
        name_json=$(jq -r '.name | @json' <<<"$item")
        desc_json=$(jq -r '.description | @json' <<<"$item")
        model=$(jq -r '.model' <<<"$item")
        file="$dir/cloud-agents-$name.md"
        {
            printf -- '---\n'
            printf 'name: %s\n' "$name_json"
            printf 'description: %s\n' "$desc_json"
            if [ -n "$model" ]; then
                printf 'model: %s\n' "$(jq -r '.model | @json' <<<"$item")"
            fi
            printf -- '---\n'
            jq -r '.systemPrompt' <<<"$item"
        } > "$file"
    done
}

# ── Subagents: OpenCode (mode: subagent; filename is the identifier) ───────
render_subagents_opencode() {
    local dir="$1"
    mkdir -p "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 -name 'cloud-agents-*.md' -delete 2>/dev/null || true
    [ -n "${CLOUD_AGENTS_SUBAGENTS_B64:-}" ] || return 0

    printf '%s' "${CLOUD_AGENTS_SUBAGENTS_B64}" | base64 -d | jq -c '.subagents[]' | while IFS= read -r item; do
        local name desc_json model file
        name=$(jq -r '.name' <<<"$item")
        desc_json=$(jq -r '.description | @json' <<<"$item")
        model=$(jq -r '.model' <<<"$item")
        file="$dir/cloud-agents-$name.md"
        {
            printf -- '---\n'
            printf 'description: %s\n' "$desc_json"
            printf 'mode: subagent\n'
            if [ -n "$model" ]; then
                printf 'model: %s\n' "$(jq -r '.model | @json' <<<"$item")"
            fi
            printf -- '---\n'
            jq -r '.systemPrompt' <<<"$item"
        } > "$file"
    done
}

# ── Subagents: Codex (one TOML file per agent) ──────────────────────────────
render_subagents_codex() {
    local dir="$1"
    mkdir -p "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 -name 'cloud-agents-*.toml' -delete 2>/dev/null || true
    [ -n "${CLOUD_AGENTS_SUBAGENTS_B64:-}" ] || return 0

    printf '%s' "${CLOUD_AGENTS_SUBAGENTS_B64}" | base64 -d | jq -c '.subagents[]' | while IFS= read -r item; do
        local name model file
        name=$(jq -r '.name' <<<"$item")
        model=$(jq -r '.model' <<<"$item")
        file="$dir/cloud-agents-$name.toml"
        {
            printf 'name = %s\n' "$(jq -r '.name | @json' <<<"$item")"
            printf 'description = %s\n' "$(jq -r '.description | @json' <<<"$item")"
            printf 'developer_instructions = %s\n' "$(jq -r '.systemPrompt | @json' <<<"$item")"
            if [ -n "$model" ]; then
                printf 'model = %s\n' "$(jq -r '.model | @json' <<<"$item")"
            fi
        } > "$file"
    done
}

# Expands ${VAR}/$VAR references in a single MCP-server env VALUE against
# this container's own real environment — so a server (seeded or
# user-authored) can write an env entry like
# "GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}" and receive the real
# credential CloudAgents.Docker already injected as a container env var,
# without that secret ever being stored in mcp_server_env (which is
# deliberately literal, non-secret config only — see
# CloudAgents.Db.mcpServersSchemaSql's doc comment). Uses `envsubst`, never
# `eval`: envsubst only replaces $VAR/${VAR} tokens with that variable's
# actual value (or empty, if unset) and never executes command
# substitution/arbitrary shell, so a value can't do anything worse than
# reference an env var by name. Falls back to the literal value, unexpanded,
# if envsubst isn't installed — matching this script's existing
# best-effort/never-crash tolerance for a missing `jq` at the top of the file.
expand_env_value() {
    if ! command -v envsubst >/dev/null 2>&1; then
        printf '%s' "$1"
        return 0
    fi
    printf '%s' "$1" | envsubst
}

# ── MCP servers: JSON-config harnesses (claude, gemini, opencode) ──────────
# $1 = target JSON config file (created with $2 as its baseline if it does
# not exist yet — an existing file, with any unrelated content, is always
# left in place). $3 = the field holding the server map ("mcpServers" for
# claude/gemini, "mcp" for opencode). Every key this script owns is prefixed
# "cloud-agents-lib-", so the strip-then-merge only ever touches its own
# prior entries.
#
# Builds up servers_json one server (and, for stdio servers, one env entry)
# at a time in a bash loop rather than a single jq expression, specifically
# so each env VALUE can be piped through expand_env_value — jq itself can't
# shell out to envsubst.
#
# NB: the "url"-transport server shape below ({"type":"http","url":...}) is
# this script's best-effort guess at each harness's remote-MCP JSON schema —
# the stdio shape (command/args/env) is the well-confirmed common case across
# all three; verify the url shape against each CLI's current docs if a
# url-transport server doesn't connect.
render_mcp_json() {
    local file="$1" baseline="$2" field="$3"
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || printf '%s' "$baseline" > "$file"

    local servers_json='{}'
    if [ -n "${CLOUD_AGENTS_MCP_SERVERS_B64:-}" ]; then
        while IFS= read -r item; do
            local name transport key entry
            name=$(jq -r '.name' <<<"$item")
            transport=$(jq -r '.transport' <<<"$item")
            key="cloud-agents-lib-$name"
            if [ "$transport" = "stdio" ]; then
                local env_json='{}' raw k v
                while IFS= read -r raw; do
                    [ -n "$raw" ] || continue
                    k="${raw%%=*}"
                    v="$(expand_env_value "${raw#*=}")"
                    env_json=$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$env_json")
                done < <(jq -r '.env[]' <<<"$item")
                entry=$(jq -c --argjson env "$env_json" '{command: .command, args: .args, env: $env}' <<<"$item")
            else
                entry=$(jq -c '{type: "http", url: .url}' <<<"$item")
            fi
            servers_json=$(jq -c --arg key "$key" --argjson value "$entry" '. + {($key): $value}' <<<"$servers_json")
        done < <(printf '%s' "${CLOUD_AGENTS_MCP_SERVERS_B64}" | base64 -d | jq -c '.mcpServers[]')
    fi

    local tmp
    tmp=$(mktemp "${file}.XXXXXX")
    jq --argjson servers "$servers_json" \
        ".${field} |= ((. // {} | with_entries(select(.key | startswith(\"cloud-agents-lib-\") | not))) + \$servers)" \
        "$file" > "$tmp"
    mv "$tmp" "$file"
}

# ── MCP servers: Codex (TOML — a marker-delimited block, since jq can't
# merge TOML). Idempotent across repeated runs: the whole block between the
# markers is stripped and re-rendered every time, never hand-merged. ───────
render_mcp_codex() {
    local file=".codex/config.toml"
    local begin="# BEGIN cloud-agents-lib-mcp-servers (managed by cloud-agents; do not edit)"
    local end="# END cloud-agents-lib-mcp-servers"
    mkdir -p .codex
    [ -f "$file" ] || : > "$file"

    local tmp
    tmp=$(mktemp "${file}.XXXXXX")
    awk -v b="$begin" -v e="$end" '
        $0 == b {skip = 1; next}
        $0 == e {skip = 0; next}
        skip != 1 {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"

    [ -n "${CLOUD_AGENTS_MCP_SERVERS_B64:-}" ] || return 0

    {
        printf '%s\n' "$begin"
        printf '%s' "${CLOUD_AGENTS_MCP_SERVERS_B64}" | base64 -d | jq -c '.mcpServers[]' | while IFS= read -r item; do
            local name transport
            name=$(jq -r '.name' <<<"$item")
            transport=$(jq -r '.transport' <<<"$item")
            printf '[mcp_servers.cloud-agents-lib-%s]\n' "$name"
            if [ "$transport" = "stdio" ]; then
                printf 'command = %s\n' "$(jq -r '.command | @json' <<<"$item")"
                printf 'args = %s\n' "$(jq -r '[.args[] | @json] | "[" + join(", ") + "]"' <<<"$item")"
                # Same per-entry expand_env_value pass as render_mcp_json — jq
                # can't shell out to envsubst, so this loops in bash instead
                # of building the TOML fragment in one jq expression.
                local env_pairs=() raw k v
                while IFS= read -r raw; do
                    [ -n "$raw" ] || continue
                    k="${raw%%=*}"
                    v="$(expand_env_value "${raw#*=}")"
                    env_pairs+=("$(jq -nr --arg k "$k" --arg v "$v" '($k|@json) + " = " + ($v|@json)')")
                done < <(jq -r '.env[]' <<<"$item")
                if [ "${#env_pairs[@]}" -gt 0 ]; then
                    # "${arr[*]}" joins on IFS's first character only, so
                    # IFS=', ' would actually join with just ",", dropping the
                    # separator space the old jq join(", ") produced.
                    local joined="" pair
                    for pair in "${env_pairs[@]}"; do
                        if [ -z "$joined" ]; then
                            joined="$pair"
                        else
                            joined="$joined, $pair"
                        fi
                    done
                    printf 'env = {%s}\n' "$joined"
                fi
            else
                printf 'url = %s\n' "$(jq -r '.url | @json' <<<"$item")"
            fi
        done
        printf '%s\n' "$end"
    } >> "$file"
}

render_skills "$SKILLS_DIR"

case "$HARNESS" in
    claude)
        render_subagents_yaml_frontmatter "$AGENTS_DIR"
        render_mcp_json ".claude/mcp.json" '{"mcpServers":{}}' "mcpServers"
        ;;
    gemini)
        render_subagents_yaml_frontmatter "$AGENTS_DIR"
        render_mcp_json ".gemini/settings.json" '{}' "mcpServers"
        ;;
    opencode)
        render_subagents_opencode "$AGENTS_DIR"
        render_mcp_json "opencode.json" '{}' "mcp"
        ;;
    codex)
        render_subagents_codex "$AGENTS_DIR"
        render_mcp_codex
        ;;
esac

# ── Branch policy rules ────────────────────────────────────────────────────
# Platform-level instructions that tell the agent to create a descriptive
# working branch before making changes. Each harness has a different
# discovery mechanism; the content is the same, only the destination differs.
# Codex is the exception: it can't use a rules file without overriding the
# user's AGENTS.md (see entrypoint-codex.sh for the prompt-prefix fallback).
# Shared logic lives in render-branch-policy.sh so tests can exercise it
# directly (#732).
source "$(dirname "${BASH_SOURCE[0]}")/render-branch-policy.sh"
render_branch_policy "$HARNESS" .
