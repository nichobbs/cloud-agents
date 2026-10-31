#!/bin/sh
# Setup script for the Claude session importer's cloud environment
# (docs/claude-session-import.md §4.1, §11). Paste it into the environment's
# setup script. It installs:
#   - /opt/claude-importer/post.sh: the one command the importer may run. It
#     fixes every curl flag and checks the endpoint path, so no extra flag
#     (-o, -K, --config, another URL) can be passed through it.
#   - /etc/claude-code/managed-settings.json: an allowlist of the four
#     read-only remote-session tools and that script; anything else is refused
#     without a prompt, and user or project settings cannot add rules.
# Both are made read-only, and immutable where the filesystem allows it.
set -eu

mkdir -p /opt/claude-importer /etc/claude-code
chattr -i /opt/claude-importer/post.sh /etc/claude-code/managed-settings.json 2>/dev/null || true

cat > /opt/claude-importer/post.sh <<'SCRIPT'
#!/bin/sh
# Claude session importer: call one cloud-agents import endpoint.
#   post.sh state
#   post.sh prompt
#   post.sh sessions/<ccr session id>/findings < chunk.json   (JSON on stdin; a heredoc)
#   post.sh sessions/<ccr session id>/findings '<json>'       (small bodies only: Linux caps
#                                                              one argument at 128 KiB)
set -eu
base="https://agents.playdium.games/api/imports/claude"
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: post.sh state|prompt|sessions/<id>/findings [json]" >&2
  exit 2
fi
path=$1
case "$path" in
  state|prompt)
    method=GET
    ;;
  sessions/*/findings)
    method=POST
    id=${path#sessions/}
    id=${id%/findings}
    case "$id" in
      session_*|cse_*) ;;
      *) echo "post.sh: not a Claude Code session id: $id" >&2; exit 2 ;;
    esac
    case "$id" in
      *[!A-Za-z0-9_]*) echo "post.sh: not a Claude Code session id: $id" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: post.sh state|prompt|sessions/<id>/findings [json]" >&2
    exit 2
    ;;
esac
have_body=0
body=""
if [ $# -eq 2 ]; then
  have_body=1
  body=$2
fi
auth=""
if [ -n "${CLOUDAGENTS_IMPORT_TOKEN:-}" ]; then
  auth="Authorization: Bearer $CLOUDAGENTS_IMPORT_TOKEN"
fi
if [ "$method" = GET ]; then
  if [ -n "$auth" ]; then
    exec curl -sS --fail-with-body --max-time 60 --proto =https -H "$auth" "$base/$path"
  fi
  exec curl -sS --fail-with-body --max-time 60 --proto =https "$base/$path"
fi
if [ "$have_body" -eq 1 ]; then
  if [ -n "$auth" ]; then
    printf '%s' "$body" | exec curl -sS --fail-with-body --max-time 120 --proto =https -H "Content-Type: application/json" -H "$auth" --data-binary @- "$base/$path"
  fi
  printf '%s' "$body" | exec curl -sS --fail-with-body --max-time 120 --proto =https -H "Content-Type: application/json" --data-binary @- "$base/$path"
fi
if [ -n "$auth" ]; then
  exec curl -sS --fail-with-body --max-time 120 --proto =https -H "Content-Type: application/json" -H "$auth" --data-binary @- "$base/$path"
fi
exec curl -sS --fail-with-body --max-time 120 --proto =https -H "Content-Type: application/json" --data-binary @- "$base/$path"
SCRIPT

cat > /etc/claude-code/managed-settings.json <<'JSON'
{
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [
      "mcp__claude-code-remote__list_sessions",
      "mcp__claude-code-remote__get_session",
      "mcp__claude-code-remote__list_events",
      "mcp__claude-code-remote__get_event",
      "Bash(/opt/claude-importer/post.sh *)"
    ]
  },
  "allowManagedPermissionRulesOnly": true
}
JSON

chown -R root:root /opt/claude-importer /etc/claude-code
chmod 555 /opt/claude-importer /opt/claude-importer/post.sh
chmod 444 /etc/claude-code/managed-settings.json
chattr +i /opt/claude-importer/post.sh /etc/claude-code/managed-settings.json 2>/dev/null \
  || echo "note: chattr is unavailable here; the files are read-only but not immutable" >&2
