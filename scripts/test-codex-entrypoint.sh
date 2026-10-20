#!/usr/bin/env bash
# Tests the end of docker/entrypoint-codex.sh: from `export CODEX_HOME=` to the
# `exec codex ...` launch. Runs that part of the real file against a temp
# workspace with a stub `codex` that records its arguments and environment.
#
# Behaviour of the pinned Codex CLI (0.145.0), checked against the real binary:
#   - the bare `codex` command is the interactive TUI. It rejects --json and
#     --full-auto (exit 2). `codex exec` is the non-interactive mode.
#   - OPENAI_API_KEY alone is not used for auth (requests go out with no bearer
#     token); CODEX_API_KEY is.
#   - it exits at startup when CODEX_HOME does not exist.
#   - it writes sqlite state, logs and a plugin checkout (with its own .git)
#     into CODEX_HOME, which here is inside the repository checkout.
#
# Set CODEX_BIN to a real codex binary to also check that every flag the
# entrypoint passes is one `codex exec` accepts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint-codex.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

grep -q '^export CODEX_HOME=/workspace/.codex$' "$ENTRYPOINT" \
  || { echo "test-codex-entrypoint: CODEX_HOME export not found in $ENTRYPOINT" >&2; exit 1; }

# The tail of the entrypoint with /workspace pointed at a temp dir.
TAIL="$WORK/tail.sh"
sed -n '/^export CODEX_HOME=/,$p' "$ENTRYPOINT" > "$TAIL.raw"
mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
: > "$CODEX_STUB_OUT"
for a in "$@"; do printf '%s\0' "$a" >> "$CODEX_STUB_OUT"; done
printf '%s\n' "${CODEX_API_KEY:-}" > "$CODEX_STUB_OUT.key"
printf '%s\n' "${CODEX_HOME:-}" > "$CODEX_STUB_OUT.home"
EOF
chmod +x "$WORK/bin/codex"

# $1: workspace dir. Remaining args: extra env.
run_tail() {
  local ws="$1"; shift
  sed "s#/workspace#$ws#g" "$TAIL.raw" > "$TAIL"
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" MODEL=gpt-test PROMPT="-starts with a dash" \
    OPENAI_API_KEY=sk-openai CODEX_STUB_OUT="$WORK/args" "$@" \
    bash -c 'set -euo pipefail; source "$0"' "$TAIL"
}

# 1. Invocation shape.
WS="$WORK/ws1"; mkdir -p "$WS"
run_tail "$WS"
mapfile -d '' -t ARGS < "$WORK/args"
has() { local a; for a in "${ARGS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
check "uses the exec subcommand"                [ "${ARGS[0]}" = exec ]
check "passes --json"                           has --json
check "bypasses Codex's sandbox (container is the sandbox)" has --dangerously-bypass-approvals-and-sandbox
check "--ephemeral keeps sessions out of the checkout" has --ephemeral
nothas() { ! has "$1"; }
check "no --full-auto (not a 0.145 flag)"       nothas --full-auto
after() { local i; for ((i = 0; i < ${#ARGS[@]} - 1; i++)); do [ "${ARGS[i]}" = "$1" ] && { printf '%s' "${ARGS[i+1]}"; return 0; }; done; return 1; }
check "model value follows --model"             [ "$(after --model)" = gpt-test ]
check "-- comes right before the prompt"        [ "${ARGS[${#ARGS[@]}-2]}" = -- ]
check "prompt is last and ends with PROMPT"     bash -c '[[ "$0" == *"-starts with a dash" ]]' "${ARGS[${#ARGS[@]}-1]}"
check "prompt carries the branch policy"        bash -c '[[ "$0" == "BRANCH POLICY:"* ]]' "${ARGS[${#ARGS[@]}-1]}"

# 2. Credentials and CODEX_HOME.
check "CODEX_API_KEY defaults to OPENAI_API_KEY" [ "$(cat "$WORK/args.key")" = sk-openai ]
check "CODEX_HOME points into the workspace"     [ "$(cat "$WORK/args.home")" = "$WS/.codex" ]
check "CODEX_HOME is created when missing"       [ -d "$WS/.codex" ]
run_tail "$WS" CODEX_API_KEY=sk-codex
check "an explicit CODEX_API_KEY is kept"        [ "$(cat "$WORK/args.key")" = sk-codex ]

# 3. Codex's runtime state is git-excluded; injected agents are not.
WS="$WORK/ws2"; mkdir -p "$WS"
git -C "$WS" init -q
run_tail "$WS"
run_tail "$WS"
mkdir -p "$WS/.codex/.tmp/plugins/.git" "$WS/.codex/agents" "$WS/.codex/shell_snapshots"
touch "$WS/.codex/state_5.sqlite" "$WS/.codex/installation_id" "$WS/.codex/.tmp/plugins/README.md" \
  "$WS/.codex/shell_snapshots/s" "$WS/.codex/config.toml" "$WS/.codex/agents/cloud-agents-a.toml" "$WS/app.py"
untracked="$(git -C "$WS" status --porcelain --untracked-files=all | sort)"
check "runtime state and config.toml are ignored" [ "$untracked" = "$(printf '?? .codex/agents/cloud-agents-a.toml\n?? app.py')" ]
check "exclude lines are not duplicated"          [ "$(grep -cxF '/.codex/*' "$WS/.git/info/exclude")" -eq 1 ]
# register-callbacks-mcp.sh excludes config.toml on its own (it holds the
# callback token); nothing here may re-include it, whatever the order.
printf '/.codex/config.toml\n' >> "$WS/.git/info/exclude"
run_tail "$WS"
check "config.toml stays ignored after a rerun"  bash -c '! git -C "$0" status --porcelain --untracked-files=all | grep -q config.toml' "$WS"

# 4. A workspace that is not a git repository still launches.
WS="$WORK/ws3"; mkdir -p "$WS"; rm -f "$WORK/args"
run_tail "$WS"
check "non-git workspace still launches codex"   [ -s "$WORK/args" ]

# 5. Against the real CLI, when one is available.
if [ -n "${CODEX_BIN:-}" ]; then
  help="$(HOME="$WORK/home" CODEX_HOME="$WORK/home" "$CODEX_BIN" exec --help 2>&1)"
  for a in "${ARGS[@]}"; do
    case "$a" in
      --) ;;
      --*) check "real codex exec accepts $a" grep -qE -- "(^|[ ,])$a([ ,=]|$)" <<< "$help" ;;
    esac
  done
fi

if [ "$fails" -gt 0 ]; then
  echo "test-codex-entrypoint: $fails check(s) failed" >&2
  exit 1
fi
echo "test-codex-entrypoint: all checks passed"
