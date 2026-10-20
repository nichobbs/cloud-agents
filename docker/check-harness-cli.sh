#!/usr/bin/env bash
# check-harness-cli.sh: verifies that an installed tool still accepts what the
# entrypoints and delegate-task.sh pass it.
#
# The runner images install the newest release of each harness CLI and of uv
# at build time (no version pins), and delegate-task.sh installs the newest
# worker CLI on demand. A release that drops or renames a flag would otherwise
# only show up as every session failing at launch, as `codex --full-auto` and
# `opencode run -q` once did. Each Dockerfile runs this right after the
# install, so such a release fails the image build instead.
#
# Usage: check-harness-cli.sh [--bin PATH] TOOL...
#        check-harness-cli.sh --list TOOL
#   TOOL: claude | codex | gemini | opencode | uv
#   --bin PATH  check this binary instead of the one on PATH (one TOOL only)
#   --list      print TOOL's required flags, one per line, and exit
#
# Required flags are the union of what the entrypoints and delegate-task.sh's
# worker commands use. scripts/test-check-harness-cli.sh fails CI if either
# passes a flag that is missing here. A flag counts as accepted when the
# tool's help for that command lists it as an option.
set -euo pipefail

# help_cmd TOOL: the arguments that print help for the command we launch.
help_cmd() {
  case "$1" in
    claude)   echo "--help" ;;
    codex)    echo "exec --help" ;;
    gemini)   echo "--help" ;;
    opencode) echo "run --help" ;;
    uv)       echo "--help" ;;
  esac
}

# required TOOL: one required flag per line.
#   claude:   docker/entrypoint.sh, delegate-task.sh
#   codex:    docker/entrypoint-codex.sh, delegate-task.sh
#   gemini:   docker/entrypoint-gemini.sh, docker/entrypoint-antigravity.sh
#             (agy is the gemini binary), delegate-task.sh
#   opencode: docker/entrypoint-opencode.sh, delegate-task.sh
#   uv:       uvx (seed/mcp-servers/fetch.json), user-tools.sh's UV_TOOL_BIN_DIR
required() {
  case "$1" in
    claude)   printf '%s\n' -p --print --model --resume --session-id --output-format --verbose \
                --dangerously-skip-permissions --permission-prompt-tool ;;
    codex)    printf '%s\n' --model --json --ephemeral --dangerously-bypass-approvals-and-sandbox \
                --skip-git-repo-check -o --output-last-message ;;
    gemini)   printf '%s\n' --model --yolo --output-format --prompt ;;
    opencode) printf '%s\n' --model --format --print-logs ;;
    uv)       printf '%s\n' tool ;;
    *) return 1 ;;
  esac
}

# Flags the tool accepts but leaves out of its help. Its parser can't be
# probed without starting a session, so these only have to appear in the
# installed program: a weaker check, kept to the flags that need it.
hidden() {
  case "$1" in
    claude) echo --permission-prompt-tool ;;
  esac
}

# Option values the launch depends on, checked as plain words in the help.
required_values() {
  case "$1" in
    claude|gemini) echo stream-json ;;
    opencode)      echo json ;;
  esac
}

if [ "${1:-}" = --list ]; then
  required "${2:-}" || { echo "check-harness-cli: unknown tool '${2:-}'" >&2; exit 2; }
  exit 0
fi

bin_override=""
if [ "${1:-}" = --bin ]; then
  bin_override="${2:-}"; shift 2
  [ "$#" -eq 1 ] || { echo "check-harness-cli: --bin takes exactly one TOOL" >&2; exit 2; }
fi
[ "$#" -gt 0 ] || { echo "usage: check-harness-cli.sh [--bin PATH] TOOL..." >&2; exit 2; }

# A scratch HOME, so help output never writes config into the image or the
# user's home volume.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

failed=0
for tool in "$@"; do
  required "$tool" > /dev/null || { echo "check-harness-cli: unknown tool '$tool'" >&2; exit 2; }
  bin="${bin_override:-$(command -v "$tool" || true)}"
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "check-harness-cli: $tool: not installed" >&2
    failed=1; continue
  fi
  version="$(HOME="$scratch" timeout 60 "$bin" --version 2> /dev/null < /dev/null | head -n 1)" || true
  [ -n "$version" ] || version="(no version)"
  hidden_list=" $(hidden "$tool" | tr '\n' ' ')"
  read -r -a args <<< "$(help_cmd "$tool")"
  help="$(HOME="$scratch" timeout 60 "$bin" "${args[@]}" 2>&1 < /dev/null)" || true
  missing=()
  while IFS= read -r flag; do
    if [[ "$hidden_list" == *" $flag "* ]]; then
      grep -aqF -- "$flag" "$(readlink -f "$bin")" || missing+=("$flag")
    elif [ "$tool" = uv ]; then
      # uv's requirement is a subcommand, listed as an indented word.
      grep -qE "^[[:space:]]+$flag([[:space:]]|$)" <<< "$help" || missing+=("$flag")
    else
      grep -qE -- "(^|[[:space:],])$flag([[:space:],=]|$)" <<< "$help" || missing+=("$flag")
    fi
  done < <(required "$tool")
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    grep -qw -- "$value" <<< "$help" || missing+=("value $value")
  done < <(required_values "$tool")
  if [ "$tool" = uv ]; then
    uvx="$(dirname "$bin")/uvx"
    { [ -x "$uvx" ] && HOME="$scratch" timeout 60 "$uvx" --version > /dev/null 2>&1 < /dev/null; } || missing+=("uvx")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "check-harness-cli: $tool $version no longer accepts what cloud-agents passes it: ${missing[*]}" >&2
    echo "check-harness-cli: update the entrypoint and delegate-task.sh to match, and this script's list" >&2
    failed=1
  else
    echo "check-harness-cli: $tool $version ok"
  fi
done
exit "$failed"
