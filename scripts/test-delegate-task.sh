#!/usr/bin/env bash
# Tests docker/delegate-task.sh against a stub `opencode` whose behaviour is
# picked by the model name, so the fallback chain, the dirty-tree stop, the
# environment scrub, --check and --worktree are all exercised offline. The
# stub writes the same NDJSON event shapes `opencode run --format json`
# emits (step_start / text / step_finish with tokens and cost), and the same
# `level=ERROR ... small=false ... error.error="..."` log line --print-logs
# writes when the free tier rate-limits the main agent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/docker/delegate-task.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/opencode" <<'STUB'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
prompt="${1:-}"
finish() {
  echo '{"type":"step_start","part":{"type":"step-start"}}'
  echo "{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"$1\"}}"
  echo '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":40,"write":0}},"cost":0}}'
}
case "$model" in
  stub/ratelimit)
    echo 'timestamp=x level=ERROR message="stream error" small=false error.error="AI_APICallError: Rate limit exceeded. Please try again later."' >&2
    sleep 60 ;;
  stub/edit)
    echo "fixed" >> calc.txt
    finish "Changed calc.txt" ;;
  stub/dirty-fail)
    echo "half" >> calc.txt
    exit 3 ;;
  stub/incomplete)
    echo '{"type":"step_finish","part":{"reason":"tool-calls","tokens":{"input":1,"output":1},"cost":0}}' ;;
  stub/env)
    env > "$STUB_ENV_DUMP"
    printf '%s' "$prompt" > "$STUB_PROMPT_DUMP"
    finish "env dumped" ;;
  stub/silent)
    sleep 60 ;;
  *)
    echo "unexpected model $model" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/opencode"

new_repo() {
  local d="$WORK/repo-$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.name test
  git -C "$d" config user.email test@example.com
  echo "start" > "$d/calc.txt"
  git -C "$d" add calc.txt
  git -C "$d" commit -q -m init
  echo "$d"
}

export PATH="$WORK/bin:$PATH"
export DELEGATE_POLL_SECS=1 DELEGATE_PROVIDER_ERROR_GRACE=2
export DELEGATE_LOG_DIR="$WORK/logs" DELEGATE_HOME="$WORK/home"

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}
field() { jq -r "$1" <<< "$out"; }

# 1. A rate-limited model that hangs is abandoned and the next one succeeds.
repo="$(new_repo fallback)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/ratelimit,stub/edit --idle 30 "fix calc")" || rc=$?
check "fallback: exit 0"                          [ "$rc" -eq 0 ]
check "fallback: status ok"                       [ "$(field .status)" = ok ]
check "fallback: model is the second one"         [ "$(field .model)" = stub/edit ]
check "fallback: first attempt is provider_error" [ "$(field '.attempts[0].outcome')" = provider_error ]
check "fallback: last_error is recorded"          [ "$(field '.attempts[0].last_error')" = "AI_APICallError: Rate limit exceeded. Please try again later." ]
check "fallback: report is the worker's text"     [ "$(field .report)" = "Changed calc.txt" ]
check "fallback: usage summed"                    [ "$(field '.usage.input + .usage.output')" = 120 ]
check "fallback: changed lists calc.txt"          [ "$(field '.changed[0]')" = " M calc.txt" ]

# 2. A failed attempt that left edits stops the chain.
repo="$(new_repo dirty)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/dirty-fail,stub/edit "fix calc")" || rc=$?
check "dirty: exit 1"                    [ "$rc" -eq 1 ]
check "dirty: status failed_dirty"       [ "$(field .status)" = failed_dirty ]
check "dirty: second model never ran"    [ "$(field '.attempts | length')" = 1 ]
check "dirty: outcome records exit code" [ "$(field '.attempts[0].outcome')" = exit_3 ]

# 3. Ending without a final stop step is a failure and falls through.
repo="$(new_repo incomplete)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/incomplete "x")" || rc=$?
check "incomplete: status failed"   [ "$(field .status)" = failed ]
check "incomplete: outcome"         [ "$(field '.attempts[0].outcome')" = incomplete ]

# 4. A silent worker is cut off by --idle.
repo="$(new_repo idle)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/silent --idle 2 "x")" || rc=$?
check "idle: outcome idle" [ "$(field '.attempts[0].outcome')" = idle ]

# 5. The worker gets a scrubbed environment and the preamble.
repo="$(new_repo env)"
export STUB_ENV_DUMP="$WORK/env.txt" STUB_PROMPT_DUMP="$WORK/prompt.txt"
rc=0; out="$(cd "$repo" && GITHUB_TOKEN=secret-gh CLAUDE_CODE_OAUTH_TOKEN=secret-oauth OPENAI_API_KEY=sk-pass \
  env STUB_ENV_DUMP="$STUB_ENV_DUMP" STUB_PROMPT_DUMP="$STUB_PROMPT_DUMP" \
  DELEGATE_PASS_ENV="OPENAI_API_KEY STUB_ENV_DUMP STUB_PROMPT_DUMP" \
  "$SCRIPT" -m stub/env "do the thing")" || rc=$?
check "env: status ok"                     [ "$(field .status)" = ok ]
check "env: GITHUB_TOKEN not passed"       bash -c "! grep -q '^GITHUB_TOKEN=' '$STUB_ENV_DUMP'"
check "env: subscription token not passed" bash -c "! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' '$STUB_ENV_DUMP'"
check "env: allowlisted key passed"        grep -q '^OPENAI_API_KEY=sk-pass$' "$STUB_ENV_DUMP"
check "env: separate HOME"                 grep -q "^HOME=$WORK/home$" "$STUB_ENV_DUMP"
check "env: preamble sent"                 grep -q 'You are a worker agent' "$STUB_PROMPT_DUMP"
check "env: spec sent"                     grep -q 'do the thing' "$STUB_PROMPT_DUMP"
rc=0; out="$(cd "$repo" && env STUB_ENV_DUMP="$STUB_ENV_DUMP" STUB_PROMPT_DUMP="$STUB_PROMPT_DUMP" \
  DELEGATE_PASS_ENV="STUB_ENV_DUMP STUB_PROMPT_DUMP" "$SCRIPT" --raw -m stub/env "bare spec")" || rc=$?
check "env: --raw sends the spec alone"    [ "$(cat "$STUB_PROMPT_DUMP")" = "bare spec" ]

# 6. --check turns a passing worker into check_failed when verification fails.
repo="$(new_repo check)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/edit --check 'grep -q nope calc.txt' "x")" || rc=$?
check "check: status check_failed" [ "$(field .status)" = check_failed ]
check "check: exit code reported"  [ "$(field .check.exit)" = 1 ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && "$SCRIPT" -m stub/edit --check 'grep -q fixed calc.txt' "x")" || rc=$?
check "check: passing check is ok" [ "$(field .status)" = ok ]

# 7. --worktree isolates the work on its own branch and commits it.
repo="$(new_repo worktree)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/edit -w task1 "x")" || rc=$?
check "worktree: status ok"               [ "$(field .status)" = ok ]
check "worktree: branch reported"         [ "$(field .branch)" = delegate/task1 ]
check "worktree: commit on branch"        [ "$(field .commit)" = "$(git -C "$repo" rev-parse delegate/task1)" ]
check "worktree: main checkout untouched" [ "$(cat "$repo/calc.txt")" = start ]
check "worktree: main checkout clean"     [ -z "$(git -C "$repo" status --porcelain)" ]
check "worktree: change is on the branch" bash -c "git -C '$repo' show delegate/task1:calc.txt | grep -q fixed"

# 8. Usage errors.
repo="$(new_repo usage)"
rc=0; (cd "$repo" && "$SCRIPT" -m stub/edit "") >/dev/null 2>&1 || rc=$?
check "usage: empty spec exits 2"        [ "$rc" -eq 2 ]
rc=0; (cd "$repo" && "$SCRIPT" -w 'bad/name' "x") >/dev/null 2>&1 || rc=$?
check "usage: bad worktree name exits 2" [ "$rc" -eq 2 ]

if [ "$fails" -gt 0 ]; then
  echo "test-delegate-task: $fails check(s) failed" >&2
  exit 1
fi
echo "test-delegate-task: all checks passed"
