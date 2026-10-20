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
  stub/child-hang)
    # A long-running command the worker started, which must die with it.
    ( sleep 4; echo "late write" >> calc.txt ) &
    sleep 60 ;;
  stub/noop)
    finish "Nothing needed changing" ;;
  stub/edit-big)
    printf 'fixed\nmore\nand more\neven more\n' >> calc.txt
    finish "Changed calc.txt a lot" ;;
  stub/new-file-fail)
    echo "new" > other.txt
    exit 5 ;;
  stub/edit-again)
    echo "more" >> calc.txt
    exit 4 ;;
  *)
    echo "unexpected model $model" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/opencode"

# Stubs for the other harnesses, emitting each CLI's real event shapes
# (checked against claude 2.1.304, codex 0.145.0 and gemini-cli 0.51.0). The
# behaviour is picked by the model name; every stub dumps its environment and
# argv to $STUB_DIR/<harness>.{env,argv} first.
mkdir -p "$WORK/hbin" "$WORK/stub"
cat > "$WORK/hbin/claude" <<'STUB'
#!/usr/bin/env bash
env > "$STUB_DIR/claude.env"; printf '%s\n' "$@" > "$STUB_DIR/claude.argv"
model=""; while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
echo '{"type":"system","subtype":"init"}'
case "$model" in
  fail) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}' ;;
  refresh-rename|refresh-older|refresh-corrupt)
    # Refresh the login the way an atomic writer does: new file, rename over.
    exp=99; [ "$model" = refresh-older ] && exp=1
    if [ "$model" = refresh-corrupt ]; then
      printf '{"claudeAiOauth":{"expiresAt":999}}\n' > "$HOME/.claude/.credentials.json.new"
    else
      printf '{"claudeAiOauth":{"accessToken":"rotated","refreshToken":"r2","expiresAt":%s}}\n' "$exp" > "$HOME/.claude/.credentials.json.new"
    fi
    mv -f "$HOME/.claude/.credentials.json.new" "$HOME/.claude/.credentials.json"
    echo "edit" >> calc.txt
    echo '{"type":"result","subtype":"success","is_error":false,"result":"refreshed","usage":{}}' ;;
  *) echo "edit" >> calc.txt
     echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
     echo '{"type":"result","subtype":"success","is_error":false,"result":"claude did it","total_cost_usd":0.25,"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":11}}' ;;
esac
STUB
cat > "$WORK/hbin/codex" <<'STUB'
#!/usr/bin/env bash
env > "$STUB_DIR/codex.env"; printf '%s\n' "$@" > "$STUB_DIR/codex.argv"
model=""; last=""; while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2 ;; -o) last="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
echo '{"type":"thread.started","thread_id":"t1"}'
echo '{"type":"turn.started"}'
case "$model" in
  fail) echo '{"type":"turn.failed","error":{"message":"usage limit reached"}}'; exit 1 ;;
  *) echo "edit" >> calc.txt
     echo '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"from the stream"}}'
     printf 'codex did it' > "$last"
     echo '{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":4,"reasoning_output_tokens":2}}' ;;
esac
STUB
cat > "$WORK/hbin/gemini" <<'STUB'
#!/usr/bin/env bash
# Enough of `gemini --help` for check-harness-cli.sh (on-demand installs).
case "${1:-}" in
  --help) printf '  %s\n' --model --yolo --output-format --prompt 'stream-json'; exit 0 ;;
  --version) echo 0.0.0-stub; exit 0 ;;
esac
env > "$STUB_DIR/gemini.env"; printf '%s\n' "$@" > "$STUB_DIR/gemini.argv"
model=""; while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac; done
echo '{"type":"init","timestamp":"t","session_id":"s","model":"m"}'
echo '{"type":"message","timestamp":"t","role":"user","content":"task"}'
case "$model" in
  fail) echo '{"type":"error","timestamp":"t","severity":"error","message":"RESOURCE_EXHAUSTED"}'
        echo '{"type":"result","timestamp":"t","status":"error","stats":{}}' ;;
  *) echo "edit" >> calc.txt
     echo '{"type":"message","timestamp":"t","role":"assistant","content":"gemini ","delta":true}'
     echo '{"type":"message","timestamp":"t","role":"assistant","content":"did it","delta":true}'
     echo '{"type":"result","timestamp":"t","status":"success","stats":{"total_tokens":9,"input_tokens":6,"output_tokens":3,"cached":1}}' ;;
esac
STUB
chmod +x "$WORK/hbin/"*

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
# Never the real home: delegate-task links ~/.claude/.credentials.json and
# installs into ~/.local.
mkdir -p "$WORK/testhome"
export HOME="$WORK/testhome"

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

# 2b. A failed attempt that only edits an already-modified file still counts.
repo="$(new_repo dirty-again)"
echo "caller edit" >> "$repo/calc.txt"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/edit-again,stub/edit "fix calc")" || rc=$?
check "dirty-again: status failed_dirty"    [ "$(field .status)" = failed_dirty ]
check "dirty-again: second model never ran" [ "$(field '.attempts | length')" = 1 ]

# 2c. Outside a git repo, a failed attempt's edits still stop the chain.
nogit="$WORK/nogit"; mkdir -p "$nogit"; echo start > "$nogit/calc.txt"
sleep 1
rc=0; out="$(cd "$nogit" && "$SCRIPT" -m stub/dirty-fail,stub/edit "fix calc")" || rc=$?
check "no-git: modified file is failed_dirty"  [ "$(field .status)" = failed_dirty ]
nogit2="$WORK/nogit2"; mkdir -p "$nogit2"
rc=0; out="$(cd "$nogit2" && "$SCRIPT" -m stub/new-file-fail,stub/edit "x")" || rc=$?
check "no-git: new file is failed_dirty"       [ "$(field .status)" = failed_dirty ]
nogit3="$WORK/nogit3"; mkdir -p "$nogit3"; echo start > "$nogit3/calc.txt"
rc=0; out="$(cd "$nogit3" && "$SCRIPT" -m stub/incomplete,stub/edit "x")" || rc=$?
check "no-git: clean failure still falls back" [ "$(field .status)" = ok ]

# 3. Ending without a final stop step is a failure and falls through.
repo="$(new_repo incomplete)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/incomplete "x")" || rc=$?
check "incomplete: status failed"   [ "$(field .status)" = failed ]
check "incomplete: outcome"         [ "$(field '.attempts[0].outcome')" = incomplete ]

# 4. A silent worker is cut off by --idle.
repo="$(new_repo idle)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/silent --idle 2 "x")" || rc=$?
check "idle: outcome idle" [ "$(field '.attempts[0].outcome')" = idle ]

# 4b. Killing an attempt also kills what the worker started.
repo="$(new_repo child)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/child-hang --idle 2 "x")" || rc=$?
sleep 4
check "child: outcome idle"            [ "$(field '.attempts[0].outcome')" = idle ]
check "child: orphan did not write"    [ "$(cat "$repo/calc.txt")" = start ]

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
check "env: per-harness HOME"             grep -q "^HOME=$WORK/home/opencode$" "$STUB_ENV_DUMP"
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
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && GITHUB_TOKEN=secret-gh CLAUDE_CODE_OAUTH_TOKEN=secret-oauth \
  "$SCRIPT" -m stub/edit --check 'test -z "${GITHUB_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}"' "x")" || rc=$?
check "check: runs with the scrubbed env" [ "$(field .status)" = ok ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && "$SCRIPT" -m stub/edit -t 2 --check 'sleep 30' "x")" || rc=$?
check "check: a hanging check is stopped"  [ "$(field .status)" = check_failed ]
check "check: timeout reported as 124"     [ "$(field .check.exit)" = 124 ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && "$SCRIPT" -m stub/edit -t 2 --check '( sleep 4; echo late >> calc.txt ) & sleep 30' "x")" || rc=$?
sleep 4
check "check: timeout also stops what the check started" bash -c "! grep -q late '$repo/calc.txt'"

# 7. --worktree isolates the work on its own branch and commits it.
repo="$(new_repo worktree)"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/edit -w task1 "x")" || rc=$?
check "worktree: status ok"               [ "$(field .status)" = ok ]
check "worktree: branch reported"         [ "$(field .branch)" = delegate/task1 ]
check "worktree: commit on branch"        [ "$(field .commit)" = "$(git -C "$repo" rev-parse delegate/task1)" ]
check "worktree: main checkout untouched" [ "$(cat "$repo/calc.txt")" = start ]
check "worktree: main checkout clean"     [ -z "$(git -C "$repo" status --porcelain)" ]
check "worktree: change is on the branch" bash -c "git -C '$repo' show delegate/task1:calc.txt | grep -q fixed"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$WORK" > "$repo/.git/hooks/pre-commit"
cp "$repo/.git/hooks/pre-commit" "$repo/.git/hooks/post-commit"
chmod +x "$repo/.git/hooks/pre-commit" "$repo/.git/hooks/post-commit"
rc=0; out="$(cd "$repo" && "$SCRIPT" -m stub/edit -w task2 "x")" || rc=$?
check "worktree: commit made with hooks present" [ "$(field .commit)" != null ]
check "worktree: repo hooks not run on commit"   [ ! -e "$WORK/hook-ran" ]

# 9. Other harnesses: success, failure fallback, report text and usage.
export STUB_DIR="$WORK/stub"
hb() { env DELEGATE_CLAUDE_BIN="$WORK/hbin/claude" DELEGATE_CODEX_BIN="$WORK/hbin/codex" \
  DELEGATE_GEMINI_BIN="$WORK/hbin/gemini" DELEGATE_PASS_ENV="STUB_DIR" "$@"; }
repo="$(new_repo claude)"
rc=0; out="$(cd "$repo" && hb ANTHROPIC_API_KEY=sk-ant "$SCRIPT" -m claude:fail,claude:sonnet "x")" || rc=$?
check "claude: ok after a failed attempt"       [ "$(field .status)" = ok ]
check "claude: harness and model reported"      [ "$(field '.harness + ":" + .model')" = claude:sonnet ]
check "claude: failed attempt is incomplete"    [ "$(field '.attempts[0].outcome')" = incomplete ]
check "claude: report from the result event"    [ "$(field .report)" = "claude did it" ]
check "claude: usage and cost"                  [ "$(field '[.usage.input,.usage.output,.usage.cache_read,.usage.cost] | map(tostring) | join(",")')" = "7,3,11,0.25" ]
check "claude: runs headless, unattended"       bash -c "grep -qx -- '-p' '$STUB_DIR/claude.argv' && grep -qx -- '--dangerously-skip-permissions' '$STUB_DIR/claude.argv'"
check "claude: api key used without a login"    [ "$(field '.attempts[1].auth')" = api_key ]

repo="$(new_repo codex)"
rc=0; out="$(cd "$repo" && hb OPENAI_API_KEY=sk-oai "$SCRIPT" -m codex:fail,codex:gpt-5.5 "x")" || rc=$?
check "codex: ok after turn.failed"             [ "$(field .status)" = ok ]
check "codex: turn.failed message recorded"     [ "$(field '.attempts[0].last_error')" = "usage limit reached" ]
check "codex: report from the -o file"          [ "$(field .report)" = "codex did it" ]
check "codex: usage summed"                     [ "$(field '[.usage.input,.usage.output,.usage.reasoning,.usage.cache_read] | map(tostring) | join(",")')" = "20,4,2,5" ]
check "codex: exec --json"                      bash -c "head -2 '$STUB_DIR/codex.argv' | tr '\n' ' ' | grep -q '^exec --json'"
check "codex: CODEX_API_KEY from OPENAI_API_KEY" grep -qx "CODEX_API_KEY=sk-oai" "$STUB_DIR/codex.env"

repo="$(new_repo gemini)"
rc=0; out="$(cd "$repo" && hb GEMINI_API_KEY=g-key "$SCRIPT" -m gemini:fail,gemini:gemini-3-flash "x")" || rc=$?
check "gemini: ok after status error"           [ "$(field .status)" = ok ]
check "gemini: report joins the deltas"         [ "$(field .report)" = "gemini did it" ]
check "gemini: usage from stats"                [ "$(field '[.usage.input,.usage.output,.usage.cache_read] | map(tostring) | join(",")')" = "6,3,1" ]
check "gemini: api key mode"                    bash -c "grep -qx 'GEMINI_API_KEY=g-key' '$STUB_DIR/gemini.env' && ! grep -q '^GOOGLE_GENAI_USE_GCA=' '$STUB_DIR/gemini.env'"

# 10. Each worker gets only its own harness's credentials.
repo="$(new_repo creds)"
rc=0; out="$(cd "$repo" && hb ANTHROPIC_API_KEY=sk-ant OPENAI_API_KEY=sk-oai GEMINI_API_KEY=g-key GITHUB_TOKEN=gh \
  "$SCRIPT" -m codex:x "x")" || rc=$?
check "creds: codex gets no Anthropic key"      bash -c "! grep -q '^ANTHROPIC_API_KEY=' '$STUB_DIR/codex.env'"
check "creds: codex gets no Gemini key"         bash -c "! grep -q '^GEMINI_API_KEY=' '$STUB_DIR/codex.env'"
check "creds: codex gets no GITHUB_TOKEN"       bash -c "! grep -q '^GITHUB_TOKEN=' '$STUB_DIR/codex.env'"
check "creds: codex CODEX_HOME in its home"     grep -qx "CODEX_HOME=$WORK/home/codex/.codex" "$STUB_DIR/codex.env"

# 11. Subscription logins are preferred, installed newest-wins, and linked.
repo="$(new_repo login)"
auth_old='{"tokens":{"refresh_token":"old"},"last_refresh":"2026-10-01T00:00:00Z"}'
auth_new='{"tokens":{"refresh_token":"new"},"last_refresh":"2026-10-10T00:00:00Z"}'
rc=0; out="$(cd "$repo" && hb OPENAI_API_KEY=sk-oai CODEX_AUTH_JSON="$auth_new" "$SCRIPT" -m codex:x "x")" || rc=$?
check "login: codex subscription preferred"     [ "$(field '.attempts[0].auth')" = subscription ]
check "login: codex gets no api key with login"  bash -c "! grep -q '^CODEX_API_KEY=' '$STUB_DIR/codex.env'"
check "login: codex auth.json installed"        [ "$(jq -r .tokens.refresh_token "$WORK/home/codex/.codex/auth.json")" = new ]
check "login: auth.json is private"             [ "$(stat -c %a "$WORK/home/codex/.codex/auth.json")" = 600 ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb CODEX_AUTH_JSON="$auth_old" "$SCRIPT" -m codex:x "x")" || rc=$?
check "login: older vault copy does not win"    [ "$(jq -r .tokens.refresh_token "$WORK/home/codex/.codex/auth.json")" = new ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb "$SCRIPT" -m codex:x "x")" || rc=$?
check "login: stored login reused without env"  [ "$(field '.attempts[0].auth')" = subscription ]

g_creds='{"access_token":"a","refresh_token":"r","expiry_date":1792000000000}'
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb GEMINI_API_KEY=g-key GEMINI_OAUTH_CREDS_JSON="$g_creds" "$SCRIPT" -m gemini:x "x")" || rc=$?
check "login: gemini uses the Google login"     grep -qx "GOOGLE_GENAI_USE_GCA=true" "$STUB_DIR/gemini.env"
check "login: gemini gets no api key with login" bash -c "! grep -q '^GEMINI_API_KEY=' '$STUB_DIR/gemini.env'"
check "login: oauth_creds.json installed"       [ -s "$WORK/home/gemini/.gemini/oauth_creds.json" ]

realhome="$WORK/realhome"; mkdir -p "$realhome/.claude"
echo '{"claudeAiOauth":{"accessToken":"live","expiresAt":5}}' > "$realhome/.claude/.credentials.json"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb HOME="$realhome" DELEGATE_HOME="$WORK/home" ANTHROPIC_API_KEY=sk-ant "$SCRIPT" -m claude:x "x")" || rc=$?
check "login: claude session login linked"      [ "$(readlink "$WORK/home/claude/.claude/.credentials.json")" = "$realhome/.claude/.credentials.json" ]
check "login: claude gets no api key with login" bash -c "! grep -q '^ANTHROPIC_API_KEY=' '$STUB_DIR/claude.env'"
check "login: claude subscription reported"     [ "$(field '.attempts[0].auth')" = subscription ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb HOME="$realhome" DELEGATE_HOME="$WORK/home" "$SCRIPT" -m claude:refresh-rename "x")" || rc=$?
check "login: a renamed-in refresh is written back" [ "$(jq -r .claudeAiOauth.refreshToken "$realhome/.claude/.credentials.json")" = r2 ]
check "login: session copy stays private"       [ "$(stat -c %a "$realhome/.claude/.credentials.json")" = 600 ]
check "login: link restored after the refresh"  [ "$(readlink "$WORK/home/claude/.claude/.credentials.json")" = "$realhome/.claude/.credentials.json" ]
echo '{"claudeAiOauth":{"accessToken":"live","refreshToken":"keep","expiresAt":50}}' > "$realhome/.claude/.credentials.json"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb HOME="$realhome" DELEGATE_HOME="$WORK/home" "$SCRIPT" -m claude:refresh-older "x")" || rc=$?
check "login: an older worker copy is not written back" [ "$(jq -r .claudeAiOauth.refreshToken "$realhome/.claude/.credentials.json")" = keep ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && hb HOME="$realhome" DELEGATE_HOME="$WORK/home" "$SCRIPT" -m claude:refresh-corrupt "x")" || rc=$?
check "login: a newer but incomplete copy is not written back" [ "$(jq -r .claudeAiOauth.refreshToken "$realhome/.claude/.credentials.json")" = keep ]

# 12. Profile limits.
repo="$(new_repo allow)"
rm -f "$STUB_DIR/claude.argv"
rc=0; out="$(cd "$repo" && hb OPENAI_API_KEY=k CLOUD_AGENTS_DELEGATE_ALLOW="opencode:*-free, codex:gpt-5*" \
  "$SCRIPT" -m claude:sonnet,codex:o3,codex:gpt-5.5 "x")" || rc=$?
check "allow: disallowed harness skipped"       [ "$(field '.attempts[0].outcome')" = not_allowed ]
check "allow: disallowed model skipped"         [ "$(field '.attempts[1].outcome')" = not_allowed ]
check "allow: allowed entry runs"               [ "$(field '.status + " " + .model')" = "ok gpt-5.5" ]
check "allow: disallowed harness never ran"     [ ! -e "$STUB_DIR/claude.argv" ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && CLOUD_AGENTS_DELEGATE_ALLOW="opencode:*-free" "$SCRIPT" -m stub/edit "x")" || rc=$?
check "allow: opencode glob applies"            [ "$(field '.attempts[0].outcome')" = not_allowed ]
rc=0; out="$(cd "$repo" && CLOUD_AGENTS_DELEGATE_ALLOW="opencode" "$SCRIPT" -m stub/edit "x")" || rc=$?
check "allow: bare harness allows any model"    [ "$(field .status)" = ok ]

# 13. A CLI the image lacks is installed on first use, at the newest release,
# into a managed prefix, and refreshed when old.
repo="$(new_repo install)"
inst_home="$WORK/insthome"; mkdir -p "$inst_home" "$WORK/npmbin"
cat > "$WORK/npmbin/npm" <<STUB
#!/usr/bin/env bash
echo "\$@" > "$WORK/npm.args"
prefix=""; while [ \$# -gt 0 ]; do case "\$1" in --prefix) prefix="\$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "\$prefix/bin"; cp "$WORK/hbin/gemini" "\$prefix/bin/gemini"
STUB
chmod +x "$WORK/npmbin/npm"
rc=0; out="$(cd "$repo" && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$PATH" HOME="$inst_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
managed="$inst_home/.cache/cloud-agents/delegate-cli/gemini"
check "install: ran npm for the newest release" grep -q "@google/gemini-cli@latest" "$WORK/npm.args"
check "install: into the managed prefix"        [ -x "$managed/bin/gemini" ]
check "install: the prefix is a versioned dir"  [ -L "$managed" ]
check "install: then ran the worker"            [ "$(field .status)" = ok ]
first_dir="$(readlink -f "$managed")"
rm -f "$WORK/npm.args"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$PATH" HOME="$inst_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: a fresh install is reused"      [ ! -e "$WORK/npm.args" ]
echo 0 > "$managed/.installed"
sleep 1
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$PATH" HOME="$inst_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: an old install is refreshed"    [ -e "$WORK/npm.args" ]
check "install: ...into a new versioned dir"    [ "$(readlink -f "$managed")" != "$first_dir" ]
check "install: ...keeping the previous one"    [ -x "$first_dir/bin/gemini" ]
check "install: ...and ran the worker"          [ "$(field .status)" = ok ]
# A refresh that fails leaves the previous install in use.
mkdir -p "$WORK/npmfail"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/npmfail/npm"; chmod +x "$WORK/npmfail/npm"
kept="$(readlink -f "$managed")"; echo 0 > "$managed/.installed"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmfail:$PATH" HOME="$inst_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: failed refresh keeps the old"   [ "$(readlink -f "$managed")" = "$kept" ]
check "install: ...and the worker still runs"   [ "$(field .status)" = ok ]
# After a failed attempt, delegations within the retry window use the old
# install without trying again; after it, they retry.
printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 1\n' "$WORK/npmfail.calls" > "$WORK/npmfail/npm"
rm -f "$WORK/npmfail.calls"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmfail:$PATH" HOME="$inst_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: no retry within the window"     [ ! -e "$WORK/npmfail.calls" ]
check "install: ...uses the old install at once" [ "$(field .status)" = ok ]
check "install: ...without waiting"             [ "$(field '.attempts[0].seconds')" -lt 5 ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmfail:$PATH" HOME="$inst_home" DELEGATE_HOME="$WORK/home" \
  DELEGATE_INSTALL_RETRY_SECS=0 GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: retried after the window"       [ -e "$WORK/npmfail.calls" ]
# A failed first install is not retried within the window either.
rm -f "$WORK/npmfail.calls"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmfail:$PATH" HOME="$WORK/firstfail" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k "$SCRIPT" -m gemini:x "x")" || rc=$?
calls_after_first="$(wc -l < "$WORK/npmfail.calls")"
rc=0; out="$(cd "$repo" && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmfail:$PATH" HOME="$WORK/firstfail" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: failed first install backs off" [ "$(wc -l < "$WORK/npmfail.calls")" -eq "$calls_after_first" ]
check "install: ...reported not_installed"      [ "$(field '.attempts[0].outcome')" = not_installed ]
# The newest release failing the flag check falls back to the known-good one.
mkdir -p "$WORK/npmold"
cat > "$WORK/npmold/npm" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$WORK/npmold.args"
prefix=""; pkg=""; while [ \$# -gt 0 ]; do case "\$1" in --prefix) prefix="\$2"; shift 2 ;; -*) shift ;; install) shift ;; *) pkg="\$1"; shift ;; esac; done
mkdir -p "\$prefix/bin"
if [ "\${pkg##*@}" = latest ]; then
  printf '#!/usr/bin/env bash\necho "  --model --prompt"\n' > "\$prefix/bin/gemini"; chmod +x "\$prefix/bin/gemini"
else
  cp "$WORK/hbin/gemini" "\$prefix/bin/gemini"
fi
STUB
chmod +x "$WORK/npmold/npm"
rm -f "$WORK/npmold.args"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmold:$PATH" HOME="$WORK/oldhome" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: newest fails check -> fallback" grep -q "@google/gemini-cli@$("$REPO_ROOT/docker/install-harness-cli.sh" --fallback gemini)" "$WORK/npmold.args"
check "install: ...and the worker runs"         [ "$(field .status)" = ok ]
# The image's own CLI wins; one under $HOME (a user's ~/.local install) does not.
mkdir -p "$WORK/imgbin" "$WORK/homebin/.local/bin"
cp "$WORK/hbin/gemini" "$WORK/imgbin/gemini"; cp "$WORK/hbin/gemini" "$WORK/homebin/.local/bin/gemini"
rm -f "$WORK/npm.args"
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$WORK/imgbin:$PATH" HOME="$WORK/homebin" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: the image's CLI is used as is"  [ ! -e "$WORK/npm.args" ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$WORK/homebin/.local/bin:$PATH" HOME="$WORK/homebin" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: a CLI under \$HOME is not"       [ -e "$WORK/npm.args" ]
rc=0; out="$(cd "$repo" && git checkout -q -- calc.txt && env PATH="$WORK/npmbin:$PATH" HOME="$WORK/nohome" DELEGATE_HOME="$WORK/home" \
  DELEGATE_AUTO_INSTALL=0 "$SCRIPT" -m codex:x "x")" || rc=$?
check "install: disabled means not_installed"   [ "$(field '.attempts[0].outcome')" = not_installed ]
# Two delegations needing the same missing CLI install it once, not twice
# at the same time.
cat > "$WORK/npmbin/npm" <<STUB
#!/usr/bin/env bash
echo start >> "$WORK/npm.trace"; sleep 2; echo end >> "$WORK/npm.trace"
prefix=""; while [ \$# -gt 0 ]; do case "\$1" in --prefix) prefix="\$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "\$prefix/bin"; cp "$WORK/hbin/gemini" "\$prefix/bin/gemini"
STUB
par_home="$WORK/parhome"; mkdir -p "$par_home"; rm -f "$WORK/npm.trace"
repo2="$(new_repo install2)"
( cd "$repo" && git checkout -q -- calc.txt && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$PATH" HOME="$par_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x" > "$WORK/par1.json" ) &
par_pid=$!
sleep 0.5
( cd "$repo2" && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin:$PATH" HOME="$par_home" DELEGATE_HOME="$WORK/home" \
  GEMINI_API_KEY=k DELEGATE_PASS_ENV=STUB_DIR "$SCRIPT" -m gemini:x "x" > "$WORK/par2.json" )
wait "$par_pid"
check "install: parallel runs install once"     [ "$(tr '\n' ' ' < "$WORK/npm.trace")" = "start end " ]
check "install: both parallel runs succeed"     [ "$(jq -r .status "$WORK/par1.json")$(jq -r .status "$WORK/par2.json")" = okok ]
mkdir -p "$WORK/npmbin2"
cat > "$WORK/npmbin2/npm" <<STUB
#!/usr/bin/env bash
env > "$WORK/npm.env"
sleep 30
STUB
chmod +x "$WORK/npmbin2/npm"
rc=0; out="$(cd "$repo" && env -u DELEGATE_GEMINI_BIN PATH="$WORK/npmbin2:$PATH" HOME="$WORK/hanghome" DELEGATE_HOME="$WORK/home" \
  DELEGATE_INSTALL_TIMEOUT=2 GITHUB_TOKEN=gh "$SCRIPT" -m gemini:x "x")" || rc=$?
check "install: a hung install times out"       [ "$(field '.attempts[0].outcome')" = not_installed ]
check "install: ...within the timeout"          [ "$(field '.attempts[0].seconds')" -lt 20 ]
check "install: npm gets the scrubbed env"      bash -c "! grep -q '^GITHUB_TOKEN=' '$WORK/npm.env'"

# 14. Worker guidance from .delegate-guidance/.
repo="$(new_repo guidance)"
mkdir -p "$repo/.delegate-guidance/skills/lyric"
printf 'Always run lyric fmt.\nNever touch vendor/.\n' > "$repo/.delegate-guidance/AGENTS.md"
printf -- '---\nname: lyric-basics\ndescription: Lyric syntax and gotchas\n---\nBody\n' > "$repo/.delegate-guidance/skills/lyric/SKILL.md"
git -C "$repo" add .delegate-guidance && git -C "$repo" commit -q -m guidance
genv() { env STUB_ENV_DUMP="$WORK/genv.txt" STUB_PROMPT_DUMP="$WORK/gprompt.txt" DELEGATE_PASS_ENV="STUB_ENV_DUMP STUB_PROMPT_DUMP" "$@"; }
rc=0; out="$(cd "$repo" && genv "$SCRIPT" -m stub/env "the task")" || rc=$?
check "guidance: AGENTS.md is in the prompt"    grep -q "Never touch vendor/" "$WORK/gprompt.txt"
check "guidance: skill listed with its path"    grep -q -- "- lyric-basics: Lyric syntax and gotchas (.delegate-guidance/skills/lyric/SKILL.md)" "$WORK/gprompt.txt"
check "guidance: before the task"               bash -c "awk '/Never touch vendor/{g=NR} /^Task:/{t=NR} END{exit !(g && t && g < t)}' '$WORK/gprompt.txt'"
check "guidance: reported in the result"        [ "$(field '.guidance.skills | join(",")')" = lyric-basics ]
rc=0; out="$(cd "$repo" && genv "$SCRIPT" --no-guidance -m stub/env "the task")" || rc=$?
check "guidance: --no-guidance leaves it out"   bash -c "! grep -q 'Never touch vendor/' '$WORK/gprompt.txt'"
check "guidance: null when not used"            [ "$(field .guidance)" = null ]
rc=0; out="$(cd "$repo" && genv "$SCRIPT" --raw -m stub/env "the task")" || rc=$?
check "guidance: --raw sends the spec alone"    [ "$(cat "$WORK/gprompt.txt")" = "the task" ]
rc=0; out="$(cd "$repo" && genv DELEGATE_GUIDANCE_MAX=10 "$SCRIPT" -m stub/env "the task")" || rc=$?
check "guidance: long AGENTS.md is truncated"   grep -q "truncated; the rest is in .delegate-guidance/AGENTS.md" "$WORK/gprompt.txt"
mkdir -p "$WORK/extguide"; echo "External rule" > "$WORK/extguide/AGENTS.md"
rc=0; out="$(cd "$repo" && genv "$SCRIPT" --guidance "$WORK/extguide" -m stub/env "the task")" || rc=$?
check "guidance: --guidance DIR overrides"      bash -c "grep -q 'External rule' '$WORK/gprompt.txt' && ! grep -q 'Never touch vendor/' '$WORK/gprompt.txt'"
rc=0; out="$(cd "$repo" && genv "$SCRIPT" -m stub/env -w gtree "the task")" || rc=$?
check "guidance: found in a worktree too"       grep -q "(.delegate-guidance/skills/lyric/SKILL.md)" "$WORK/gprompt.txt"

# 15. Best of K.
repo="$(new_repo bestk)"
rc=0; out="$(cd "$repo" && "$SCRIPT" --k 2 -m stub/edit-big,stub/edit --check 'grep -q fixed calc.txt' -w bk "x")" || rc=$?
check "best-of-k: exit 0"                       [ "$rc" -eq 0 ]
check "best-of-k: two candidates"               [ "$(field '.candidates | length')" = 2 ]
check "best-of-k: each started elsewhere"       [ "$(field '[.candidates[].model] | join(",")')" = "stub/edit-big,stub/edit" ]
check "best-of-k: smallest passing diff wins"   [ "$(field '.selected')" = 2 ]
check "best-of-k: result is the winner's"       [ "$(field '.branch')" = delegate/bk-2 ]
check "best-of-k: winner worktree kept"         [ -d "$repo/.delegate/bk-2" ]
check "best-of-k: loser worktree removed"       [ ! -e "$repo/.delegate/bk-1" ]
check "best-of-k: loser branch removed"         bash -c "! git -C '$repo' rev-parse -q --verify delegate/bk-1 >/dev/null"
check "best-of-k: main checkout untouched"      [ "$(cat "$repo/calc.txt")" = start ]
rc=0; out="$(cd "$repo" && "$SCRIPT" --k 2 -m stub/noop,stub/edit-big -w bk5 "x")" || rc=$?
check "best-of-k: an empty ok diff does not win" [ "$(field '.selected')" = 2 ]
rc=0; out="$(cd "$repo" && "$SCRIPT" --k 2 -m stub/dirty-fail,stub/edit-big -w bk2 "x")" || rc=$?
check "best-of-k: a passing candidate beats a failing one" [ "$(field '.selected')" = 2 ]
check "best-of-k: failed candidate recorded"    [ "$(field '.candidates[0].status')" = failed_dirty ]
rc=0; out="$(cd "$repo" && "$SCRIPT" --k 2 -m stub/incomplete -w bk3 "x")" || rc=$?
check "best-of-k: all failing exits 1"          [ "$rc" -eq 1 ]
check "best-of-k: all failing selects none"     [ "$(field '.selected')" = null ]
check "best-of-k: all worktrees removed"        bash -c "[ ! -e '$repo/.delegate/bk3-1' ] && [ ! -e '$repo/.delegate/bk3-2' ]"
rc=0; out="$(cd "$repo" && "$SCRIPT" --k 2 --keep-candidates -m stub/edit-big,stub/edit -w bk4 "x")" || rc=$?
check "best-of-k: --keep-candidates keeps losers" [ -d "$repo/.delegate/bk4-1" ]
rc=0; out="$(cd "$repo" && "$SCRIPT" --k 2 -m stub/edit "x")" || rc=$?
check "best-of-k: default worktree names"       bash -c '[[ "$1" == delegate/cand-*-[12] ]]' _ "$(field '.branch')"
rc=0; (cd "$WORK" && "$SCRIPT" --k 2 -m stub/edit "x") >/dev/null 2>&1 || rc=$?
check "best-of-k: needs a git repository"       [ "$rc" -eq 2 ]

# 8. Usage errors.
repo="$(new_repo usage)"
rc=0; (cd "$repo" && "$SCRIPT" -m stub/edit "") >/dev/null 2>&1 || rc=$?
check "usage: empty spec exits 2"        [ "$rc" -eq 2 ]
rc=0; (cd "$repo" && "$SCRIPT" -w 'bad/name' "x") >/dev/null 2>&1 || rc=$?
check "usage: bad worktree name exits 2" [ "$rc" -eq 2 ]
rc=0; (cd "$repo" && "$SCRIPT" -m 'cursor:fast' "x") >/dev/null 2>&1 || rc=$?
check "usage: unknown harness exits 2"   [ "$rc" -eq 2 ]
rc=0; out="$(cd "$repo" && "$SCRIPT" -m 'stub/edit,cursor:fast' "x" 2>/dev/null)" || rc=$?
check "usage: a late typo exits 2 up front" [ "$rc" -eq 2 ]
check "usage: nothing ran before it"     [ "$(cat "$repo/calc.txt")" = start ]
rc=0; (cd "$repo" && "$SCRIPT" -m ' , ' -w orphan "x") >/dev/null 2>&1 || rc=$?
check "usage: empty model list exits 2"  [ "$rc" -eq 2 ]
check "usage: no worktree left behind"   [ ! -e "$repo/.delegate/orphan" ]

if [ "$fails" -gt 0 ]; then
  echo "test-delegate-task: $fails check(s) failed" >&2
  exit 1
fi
echo "test-delegate-task: all checks passed"
