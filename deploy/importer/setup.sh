#!/bin/sh
# Setup script for the Claude session importer's cloud environment
# (docs/claude-session-import.md §4.1). Paste it into the environment's setup
# script. It installs a managed-settings allowlist: the importer may only read
# sessions and POST to the import endpoints, and anything not allowed is
# refused without a prompt. Keep the JSON in step with managed-settings.json.
set -eu
mkdir -p /etc/claude-code
cat > /etc/claude-code/managed-settings.json <<'JSON'
{
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [
      "mcp__claude-code-remote__list_sessions",
      "mcp__claude-code-remote__get_session",
      "mcp__claude-code-remote__list_events",
      "mcp__claude-code-remote__get_event",
      "Bash(curl -sS --fail-with-body -H * https://agents.playdium.games/api/imports/claude/*)"
    ]
  },
  "allowManagedPermissionRulesOnly": true
}
JSON
chmod 444 /etc/claude-code/managed-settings.json
