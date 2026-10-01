#!/usr/bin/env bash
# Restore a refreshable Claude subscription login from the credential vault.
#
# The vault copy (CLAUDE_CREDENTIALS_JSON, the {"claudeAiOauth":{...}} object)
# is a seed, not the live login: the CLI refreshes tokens in place on the home
# volume. The newer login (larger claudeAiOauth.expiresAt) wins so a refresh is
# never clobbered by a stale vault copy, while a freshly pasted login with a
# later expiry replaces an old one. Sourced by entrypoint.sh; prints nothing
# secret.

# restore_claude_credentials <credentials-file>
# Returns 0 if the file was (re)written, 1 if left alone (not newer, or no vault
# value), 2 if the vault value is unusable (malformed, no access token, no jq).
restore_claude_credentials() {
    local file="$1"
    local vault="${CLAUDE_CREDENTIALS_JSON:-}"
    [ -n "$vault" ] || return 1
    command -v jq >/dev/null 2>&1 || return 2

    local vault_exp
    vault_exp=$(printf '%s' "$vault" | jq -r 'if (.claudeAiOauth.accessToken | type) == "string" and (.claudeAiOauth.accessToken | length) > 0 then (.claudeAiOauth.expiresAt // 0 | tonumber? // 0) else empty end' 2>/dev/null) || return 2
    [ -n "$vault_exp" ] || return 2

    local file_exp=-1
    if [ -f "$file" ]; then
        file_exp=$(jq -r 'if (.claudeAiOauth.accessToken | type) == "string" and (.claudeAiOauth.accessToken | length) > 0 then (.claudeAiOauth.expiresAt // 0 | tonumber? // 0) else -1 end' "$file" 2>/dev/null || echo -1)
        [ -n "$file_exp" ] || file_exp=-1
    fi

    # Compare with jq: expiresAt is epoch milliseconds, beyond 32-bit shell ints.
    if [ "$(jq -n --argjson v "$vault_exp" --argjson f "$file_exp" 'if $v > $f then 1 else 0 end')" != "1" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$file")"
    local tmp
    tmp=$(mktemp "$(dirname "$file")/.credentials.XXXXXX") || return 1
    printf '%s\n' "$vault" | jq -c '{claudeAiOauth: .claudeAiOauth}' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
    return 0
}

# claude_credentials_usable <credentials-file>
# True when the file holds a non-empty claudeAiOauth.accessToken.
claude_credentials_usable() {
    [ -f "$1" ] && command -v jq >/dev/null 2>&1 &&
        jq -e '(.claudeAiOauth.accessToken | type) == "string" and (.claudeAiOauth.accessToken | length) > 0' "$1" >/dev/null 2>&1
}
