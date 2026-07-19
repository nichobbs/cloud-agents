#!/usr/bin/env bash
# Regression test for docker/entrypoint-opencode.sh's `opencode run` invocation
# (#17).
#
# Verified 2026-07-19 against https://opencode.ai/docs/cli/ (the official
# OpenCode CLI docs):
#   - `opencode run [message..]` takes the prompt as a POSITIONAL argument —
#     confirmed correct here (this file's invocation passes "${PROMPT}" as
#     the last, non-flag token).
#   - `--model`/`-m` expects the form `provider/model` (e.g.
#     `anthropic/claude-sonnet-4-6`), NOT a bare model id.
#
# That second point is a real, currently-UNRESOLVED discrepancy: every MODEL
# value this app stores/passes for the opencode harness (see
# CloudAgents.SessionStore.defaultModelForHarness("opencode") and every
# opencode model string surfaced in the UI/API) is a bare id like
# "claude-sonnet-4-6", with no "anthropic/" (or similar) provider prefix. This
# script does NOT attempt to fix that — the fix would need to trace through
# every place this app stores/displays an opencode model id, which is a
# larger, product-level change this regression test isn't the place to make
# unilaterally. It only pins the CURRENT invocation SHAPE (subcommand, flag,
# `--` separator, positional prompt) as a regression guard, and documents the
# --model format gap for a dedicated follow-up.
#
# The `--` separator before "${PROMPT}" isn't separately documented by
# OpenCode, but is standard getopt-style behavior and protects a
# user-supplied prompt that happens to start with '-' from being misread as a
# flag — worth keeping regardless of the --model question above.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint-opencode.sh"
[ -f "$ENTRYPOINT" ] || { echo "test-opencode-entrypoint: $ENTRYPOINT not found" >&2; exit 1; }

LINE="$(grep -E '^\s*exec opencode run ' "$ENTRYPOINT" || true)"
if [ -z "$LINE" ]; then
  echo "FAIL: no 'exec opencode run' invocation found in $ENTRYPOINT" >&2
  exit 1
fi

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

matches() { [[ "$LINE" == *"$1"* ]]; }
endswith() { [[ "$LINE" == *"$1" ]]; }

check "invokes the 'run' subcommand"                                       matches "opencode run"
check "passes --model"                                                     matches "--model"
check "MODEL immediately follows --model"                                  matches '--model "${MODEL}"'
check "uses a -- separator before the prompt (protects a leading '-')"     matches '-- "${PROMPT}"'
check "the prompt is the final (positional) token on the invocation line"  endswith '"${PROMPT}"'

if [ "$fails" -gt 0 ]; then
  echo "test-opencode-entrypoint: $fails check(s) failed" >&2
  exit 1
fi
echo "test-opencode-entrypoint: all checks passed"
