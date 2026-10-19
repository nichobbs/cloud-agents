#!/usr/bin/env bash
# delegate-task — hand a well-specified coding task to a cheaper worker model
# through the OpenCode CLI, and print one compact JSON result.
#
# The orchestrating agent (Claude Code on the owner's subscription) writes the
# spec and checks the result; the worker does the token-heavy loop of reading
# files, editing, building and retrying. The point is that the orchestrator
# never sees the worker's transcript: it gets status, a short summary, the
# changed files and, with --check, the exit code of a verification command.
# See docs/delegation.md for the design and the measurements behind it.
#
# Usage:
#   delegate-task [options] SPEC
#   delegate-task [options] -          (spec on stdin)
#   delegate-task [options] --spec-file FILE
#
# Options:
#   -m, --models LIST    comma-separated fallback chain, tried in order
#                        (default: $DELEGATE_MODELS, else the free chain below).
#                        A bare id ("big-pickle") means "opencode/<id>".
#   -t, --timeout SECS   hard limit per attempt (default 900)
#       --idle SECS      give up on an attempt that emits no event for SECS
#                        (default 180)
#   -C, --dir DIR        run in DIR instead of the current directory
#   -w, --worktree NAME  run in a fresh git worktree <repo>/.delegate/NAME on
#                        branch delegate/NAME; on success the worker's changes
#                        are committed there for the caller to review and merge
#       --check CMD      after a successful attempt, run CMD (bash -c) in the
#                        working directory and report its exit code and tail
#       --max-text N     truncate the worker's final message to N characters
#                        (default 2000)
#       --raw            send SPEC as-is, without the worker preamble
#   -h, --help
#
# Fallback: the next model is tried when an attempt times out, goes idle, hits
# a provider error it does not recover from (the free tier's "Rate limit
# exceeded" leaves `opencode run` hanging rather than exiting), or ends
# without a final "stop" step. If a failed attempt already changed files, the
# chain stops with status "failed_dirty" instead of letting the next model
# build on a half-finished edit; nothing is reset for you.
#
# Isolation: the worker runs with a scrubbed environment. Only locale, proxy,
# CA and the model keys in DELEGATE_PASS_ENV reach it, so the subscription
# token, GITHUB_TOKEN and the callback shim's credentials do not. It runs as
# the same OS user with its own HOME (DELEGATE_HOME), which keeps its state out
# of the session's home volume but is not a security boundary.
#
# Exit status: 0 when status is "ok", 1 for any other result, 2 for usage
# errors. The JSON is printed either way (except for usage errors).
set -uo pipefail

DEFAULT_MODELS="opencode/nemotron-3.5-lightning-free,opencode/nemotron-3.5-super-vl-free,opencode/big-pickle,opencode/glm-5.3-flash-free,opencode/deepseek-v4.1-flash-free"
DEFAULT_PASS_ENV="OPENCODE_API_KEY OPENCODE_ZEN_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENERATIVE_AI_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY"

# Seconds an attempt may stay silent after the main agent logged a provider
# error before it counts as stuck. opencode retries some errors itself
# ("Endpoint is unavailable" has been seen to recover), so this is not zero.
PROVIDER_ERROR_GRACE="${DELEGATE_PROVIDER_ERROR_GRACE:-20}"
POLL_SECS="${DELEGATE_POLL_SECS:-2}"
OPENCODE_BIN="${DELEGATE_OPENCODE_BIN:-opencode}"

usage() { sed -n '2,/^set -uo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die_usage() { echo "delegate-task: $1" >&2; exit 2; }

models="${DELEGATE_MODELS:-$DEFAULT_MODELS}"
timeout_secs=900
idle_secs=180
workdir=""
worktree=""
check_cmd=""
max_text=2000
raw=0
spec=""
spec_file=""
have_spec=0

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--models)   [ $# -ge 2 ] || die_usage "$1 needs a value"; models="$2"; shift 2 ;;
    -t|--timeout)  [ $# -ge 2 ] || die_usage "$1 needs a value"; timeout_secs="$2"; shift 2 ;;
    --idle)        [ $# -ge 2 ] || die_usage "$1 needs a value"; idle_secs="$2"; shift 2 ;;
    -C|--dir)      [ $# -ge 2 ] || die_usage "$1 needs a value"; workdir="$2"; shift 2 ;;
    -w|--worktree) [ $# -ge 2 ] || die_usage "$1 needs a value"; worktree="$2"; shift 2 ;;
    --check)       [ $# -ge 2 ] || die_usage "$1 needs a value"; check_cmd="$2"; shift 2 ;;
    --max-text)    [ $# -ge 2 ] || die_usage "$1 needs a value"; max_text="$2"; shift 2 ;;
    --spec-file)   [ $# -ge 2 ] || die_usage "$1 needs a value"; spec_file="$2"; shift 2 ;;
    --raw)         raw=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; [ $# -ge 1 ] && { spec="$1"; have_spec=1; shift; } ;;
    -)             spec="$(cat)"; have_spec=1; shift ;;
    -*)            die_usage "unknown option $1" ;;
    *)             [ "$have_spec" -eq 0 ] || die_usage "more than one SPEC given"; spec="$1"; have_spec=1; shift ;;
  esac
done

if [ -n "$spec_file" ]; then
  [ "$have_spec" -eq 0 ] || die_usage "give SPEC or --spec-file, not both"
  [ -r "$spec_file" ] || die_usage "cannot read $spec_file"
  spec="$(cat "$spec_file")"
fi
[ -n "${spec//[[:space:]]/}" ] || die_usage "empty SPEC (see --help)"
for n in "$timeout_secs" "$idle_secs" "$max_text"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die_usage "expected a positive integer, got '$n'"
done
if [ -n "$worktree" ] && ! [[ "$worktree" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die_usage "worktree name may only contain letters, digits, '.', '_' and '-'"
fi
command -v jq >/dev/null 2>&1 || die_usage "jq is required"
command -v "$OPENCODE_BIN" >/dev/null 2>&1 || die_usage "'$OPENCODE_BIN' not found on PATH"

[ -n "${models//[[:space:],]/}" ] || die_usage "no models given"
command -v setsid >/dev/null 2>&1 || die_usage "setsid is required"

if [ -n "$workdir" ]; then
  cd "$workdir" || die_usage "cannot cd to $workdir"
fi

branch=""
if [ -n "$worktree" ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die_usage "--worktree needs a git repository"
  wt_path="$top/.delegate/$worktree"
  branch="delegate/$worktree"
  [ ! -e "$wt_path" ] || die_usage "$wt_path already exists"
  exclude="$(git rev-parse --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '/.delegate/' "$exclude" 2>/dev/null || echo '/.delegate/' >> "$exclude"
  git worktree add -q -b "$branch" "$wt_path" HEAD >&2 || die_usage "git worktree add failed"
  cd "$wt_path" || exit 2
fi
workdir="$(pwd)"
in_git=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

run_id="$(date +%Y%m%d-%H%M%S)-$$"
log_root="${DELEGATE_LOG_DIR:-${TMPDIR:-/tmp}/delegate}/$run_id"
mkdir -p "$log_root"
worker_home="${DELEGATE_HOME:-${TMPDIR:-/tmp}/delegate-home}"
mkdir -p "$worker_home"

if [ "$raw" -eq 1 ]; then
  prompt="$spec"
else
  prompt="You are a worker agent. Another agent wrote the task below and will check your result.

Rules:
- Work only inside the current directory.
- Do not commit, push, create branches or open pull requests.
- Do not ask questions: if something is ambiguous, pick the most reasonable reading and say so at the end.
- Run the build or tests the task names before you finish, and fix what fails.
- Finish with a short plain-text report: what you changed (file paths), what you ran and its result, and anything left unresolved.

Task:
$spec"
fi

# Environment handed to the worker: nothing the session holds beyond what a
# model call needs.
worker_env=(
  "PATH=$PATH"
  "HOME=$worker_home"
  "LANG=${LANG:-C.UTF-8}"
  "TERM=dumb"
  "TMPDIR=${TMPDIR:-/tmp}"
)
for v in USER LC_ALL NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR \
         HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
         ${DELEGATE_PASS_ENV:-$DEFAULT_PASS_ENV}; do
  if [ -n "${!v:-}" ]; then
    worker_env+=("$v=${!v}")
  fi
done

changed_files() {
  [ "$in_git" -eq 1 ] && git status --porcelain --untracked-files=all 2>/dev/null
}
# Content, not just the file list: a worker that edits a file the caller had
# already modified leaves `git status` unchanged.
tree_fingerprint() {
  [ "$in_git" -eq 1 ] || return 0
  changed_files
  git diff HEAD 2>/dev/null | sha1sum
  git ls-files --others --exclude-standard -z 2>/dev/null | xargs -0 -r sha1sum 2>/dev/null
}
start_fingerprint="$(tree_fingerprint)"

# Runs one attempt; sets attempt_outcome to ok|timeout|idle|provider_error|
# exit_<n>|incomplete.
run_attempt() {
  local model="$1" out="$2" err="$3"
  local zen_key="${OPENCODE_ZEN_API_KEY:-${OPENCODE_API_KEY:-}}"
  local -a env_for=("${worker_env[@]}")
  # The free opencode/* models need some key value to be set; the entrypoint
  # for the opencode harness uses the same placeholder.
  if [[ "$model" == opencode/* ]] && [ -z "$zen_key" ]; then
    env_for+=("OPENCODE_ZEN_API_KEY=free-model-placeholder")
  fi

  : > "$out"; : > "$err"
  # Its own session and process group, so a kill also reaches the build and
  # test commands the worker started; otherwise they would keep running (and
  # editing) while the next model works.
  setsid env -i "${env_for[@]}" "$OPENCODE_BIN" run --print-logs --model "$model" --format json -- "$prompt" \
    < /dev/null > "$out" 2> "$err" &
  local pid=$!
  local start now last_change last_size size err_seen=0 err_count error_at=0
  start=$(date +%s); last_change=$start; last_size=0
  attempt_outcome=""

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$POLL_SECS"
    now=$(date +%s)
    size=$(wc -c < "$out")
    if [ "$size" -ne "$last_size" ]; then
      last_size=$size; last_change=$now
    fi
    err_count=$(grep -c 'level=ERROR.*small=false' "$err" 2>/dev/null)
    if [ "${err_count:-0}" -gt "$err_seen" ]; then
      err_seen=$err_count; error_at=$now
    fi
    if [ $((now - start)) -ge "$timeout_secs" ]; then
      attempt_outcome="timeout"
    elif [ "$error_at" -gt 0 ] && [ "$last_change" -le "$error_at" ] && [ $((now - error_at)) -ge "$PROVIDER_ERROR_GRACE" ]; then
      attempt_outcome="provider_error"
    elif [ $((now - last_change)) -ge "$idle_secs" ]; then
      attempt_outcome="idle"
    fi
    if [ -n "$attempt_outcome" ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return
    fi
  done
  wait "$pid"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    attempt_outcome="exit_$rc"
  elif jq -e -s 'map(select(.type=="step_finish")) | last | .part.reason == "stop"' "$out" >/dev/null 2>&1; then
    attempt_outcome="ok"
  else
    attempt_outcome="incomplete"
  fi
}

attempts_json="[]"
final_status="failed"
final_model=""
final_out=""
i=0
IFS=',' read -r -a model_list <<< "$models"
for raw_model in "${model_list[@]}"; do
  model="$(echo "$raw_model" | tr -d '[:space:]')"
  [ -n "$model" ] || continue
  [[ "$model" == */* ]] || model="opencode/$model"
  i=$((i + 1))
  out="$log_root/attempt-$i.ndjson"
  err="$log_root/attempt-$i.log"
  t0=$(date +%s)
  run_attempt "$model" "$out" "$err"
  secs=$(( $(date +%s) - t0 ))
  provider_error="$(grep -o 'error.error="[^"]*"' "$err" 2>/dev/null | tail -1 | sed 's/^error.error="//; s/"$//')"
  attempts_json="$(jq -c --arg m "$model" --arg o "$attempt_outcome" --argjson s "$secs" --arg e "$provider_error" \
    '. + [{model: $m, outcome: $o, seconds: $s} + (if $e == "" then {} else {last_error: $e} end)]' <<< "$attempts_json")"
  final_model="$model"
  final_out="$out"
  if [ "$attempt_outcome" = "ok" ]; then
    final_status="ok"
    break
  fi
  if [ "$(tree_fingerprint)" != "$start_fingerprint" ]; then
    final_status="failed_dirty"
    break
  fi
done

# Worker's own report and usage, from the attempt that ended the chain.
final_text=""
usage_json='{"input":0,"output":0,"reasoning":0,"cache_read":0,"cost":0}'
if [ -s "$final_out" ]; then
  final_text="$(jq -r -s 'map(select(.type=="text") | .part.text) | last // ""' "$final_out" 2>/dev/null)"
  usage_json="$(jq -c -s 'map(select(.type=="step_finish") | .part) |
    {input: (map(.tokens.input // 0) | add // 0),
     output: (map(.tokens.output // 0) | add // 0),
     reasoning: (map(.tokens.reasoning // 0) | add // 0),
     cache_read: (map(.tokens.cache.read // 0) | add // 0),
     cost: (map(.cost // 0) | add // 0)}' "$final_out" 2>/dev/null || echo "$usage_json")"
fi
if [ "${#final_text}" -gt "$max_text" ]; then
  final_text="${final_text:0:$max_text}... [truncated; full transcript in $final_out]"
fi

changed="$(changed_files)"
diffstat=""
[ "$in_git" -eq 1 ] && diffstat="$(git diff HEAD --stat 2>/dev/null | tail -20)"

check_json="null"
if [ "$final_status" = "ok" ] && [ -n "$check_cmd" ]; then
  check_log="$log_root/check.log"
  bash -c "$check_cmd" > "$check_log" 2>&1
  check_rc=$?
  check_json="$(jq -n -c --arg c "$check_cmd" --argjson rc "$check_rc" --arg t "$(tail -c 1500 "$check_log")" \
    '{cmd: $c, exit: $rc, tail: $t}')"
  [ "$check_rc" -eq 0 ] || final_status="check_failed"
fi

commit=""
if [ -n "$branch" ] && [ "$final_status" = "ok" ] && [ -n "$changed" ]; then
  git add -A
  if git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo delegate-worker)}" \
         -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo delegate-worker@localhost)}" \
         commit -q -m "delegate($worktree): worker changes from $final_model" >&2; then
    commit="$(git rev-parse HEAD)"
  fi
fi

jq -n \
  --arg status "$final_status" \
  --arg model "$final_model" \
  --argjson attempts "$attempts_json" \
  --argjson usage "$usage_json" \
  --arg report "$final_text" \
  --arg changed "$changed" \
  --arg diffstat "$diffstat" \
  --argjson check "$check_json" \
  --arg workdir "$workdir" \
  --arg branch "$branch" \
  --arg commit "$commit" \
  --arg logs "$log_root" \
  '{status: $status, model: $model, attempts: $attempts, usage: $usage,
    report: $report,
    changed: ($changed | split("\n") | map(select(length > 0))),
    diffstat: $diffstat, check: $check, workdir: $workdir, logs: $logs}
   + (if $branch == "" then {} else {branch: $branch, commit: (if $commit == "" then null else $commit end)} end)'

[ "$final_status" = "ok" ]
