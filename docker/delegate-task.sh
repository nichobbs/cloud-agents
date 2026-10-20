#!/usr/bin/env bash
# delegate-task — hand a well-specified coding task to a worker agent on
# another (usually cheaper) model or harness, and print one compact JSON result.
#
# Workers run through a harness CLI: opencode, claude, codex or gemini. The
# orchestrating agent, on any harness, writes the spec and checks the result; the worker does the token-heavy loop of reading
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
#                        Each entry is HARNESS:MODEL, e.g. codex:gpt-5.5,
#                        claude:sonnet, gemini:gemini-3-flash, opencode:big-pickle.
#                        "HARNESS:" uses that harness's default model. An entry
#                        without a harness is an OpenCode model, and a bare
#                        OpenCode id ("big-pickle") means "opencode/<id>".
#   -t, --timeout SECS   hard limit per attempt (default 900)
#       --idle SECS      give up on an attempt that emits no event for SECS
#                        (default 180)
#   -C, --dir DIR        run in DIR instead of the current directory
#   -w, --worktree NAME  run in a fresh git worktree <repo>/.delegate/NAME on
#                        branch delegate/NAME; on success the worker's changes
#                        are committed there for the caller to review and merge
#       --check CMD      after a successful attempt, run CMD (bash -c) in the
#                        working directory and report its exit code and tail;
#                        it runs worker-written code, so it gets the worker's
#                        scrubbed environment, not the session's, and the
#                        same --timeout (a timeout reports exit 124)
#       --max-text N     truncate the worker's final message to N characters
#                        (default 2000)
#       --raw            send SPEC as-is, without the worker preamble or guidance
#       --guidance DIR   worker guidance to include (default: $DELEGATE_GUIDANCE_DIR,
#                        else .delegate-guidance/ at the repository root, if any):
#                        DIR/AGENTS.md is put in the prompt, and each
#                        DIR/skills/*/SKILL.md is listed by name, description
#                        and path for the worker to read when it applies
#       --no-guidance    include no worker guidance
#       --k N            best of N: run N candidates in parallel, each in its own
#                        worktree (-w NAME gives NAME-1..NAME-N, default cand-<time>)
#                        and starting at a different chain entry; keep a passing
#                        one with the smallest diff and remove the others
#       --keep-candidates  keep the worktrees and branches of unselected candidates
#   -h, --help
#
# Fallback: the next entry is tried when an attempt times out, goes idle, hits
# a provider error it does not recover from (the free tier's "Rate limit
# exceeded" leaves `opencode run` hanging rather than exiting), ends without a
# successful final event, is not allowed by the profile, or its CLI is missing
# and cannot be installed. If a failed attempt already changed files, the
# chain stops with status "failed_dirty" instead of letting the next model
# build on a half-finished edit; nothing is reset for you.
#
# Credentials: a worker gets only its own harness's credentials, preferring a
# subscription login over an API key (the point is to spend subscriptions):
#   claude    ~/.claude/.credentials.json (linked, not copied), else
#             CLAUDE_CREDENTIALS_JSON or CLAUDE_CODE_OAUTH_TOKEN, else
#             ANTHROPIC_API_KEY
#   codex     CODEX_AUTH_JSON (a ChatGPT login's ~/.codex/auth.json), else
#             CODEX_API_KEY / OPENAI_API_KEY
#   gemini    GEMINI_OAUTH_CREDS_JSON (a Google login's
#             ~/.gemini/oauth_creds.json), else GEMINI_API_KEY / GOOGLE_API_KEY
#   opencode  OPENCODE_API_KEY and provider keys; free opencode/* models need none
# Login files live in a per-harness worker HOME on the home volume
# (DELEGATE_HOME, default ~/.cache/cloud-agents/delegate/<harness>), are only
# overwritten by a newer vault copy, and are refreshed in place by the CLI, so
# a rotated refresh token is not lost between runs. Plus locale, proxy, CA and
# any names in DELEGATE_PASS_ENV. GITHUB_TOKEN and the callback shim's
# credentials are not passed. This is hygiene, not a security boundary: a
# same-user process can still read the session user's files and other
# processes' /proc/<pid>/environ.
#
# Profile limits: CLOUD_AGENTS_DELEGATE_ALLOW, when set, is a comma-separated
# list of HARNESS or HARNESS:MODEL-GLOB patterns (opencode:*-free, codex:gpt-5*,
# claude); entries matching none are skipped as "not_allowed".
#
# A CLI the image doesn't ship is installed on first use into
# ~/.cache/cloud-agents/delegate-cli/<harness> by install-harness-cli.sh: the
# newest release, checked against the flags used here, with a known-good
# fallback. It is refreshed once it is DELEGATE_REFRESH_DAYS old (default 7);
# after a failed attempt the existing install, if any, is used without retrying
# for DELEGATE_INSTALL_RETRY_SECS (default 3600). DELEGATE_AUTO_INSTALL=0 turns
# installing off.
#
# Exit status: 0 when status is "ok", 1 for any other result, 2 for usage
# errors. The JSON is printed either way (except for usage errors).
set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

DEFAULT_MODELS="opencode/nemotron-3.5-lightning-free,opencode/nemotron-3.5-super-vl-free,opencode/big-pickle,opencode/glm-5.3-flash-free,opencode/deepseek-v4.1-flash-free"
OPENCODE_KEYS="OPENCODE_API_KEY OPENCODE_ZEN_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENERATIVE_AI_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY"
HARNESSES="opencode claude codex gemini"


# Seconds an attempt may stay silent after the main agent logged a provider
# error before it counts as stuck. opencode retries some errors itself
# ("Endpoint is unavailable" has been seen to recover), so this is not zero.
PROVIDER_ERROR_GRACE="${DELEGATE_PROVIDER_ERROR_GRACE:-20}"
# The other harnesses only match a generic pattern on their stderr and retry
# rate limits themselves with backoff, so they get longer before an attempt
# counts as stuck.
OTHER_PROVIDER_ERROR_GRACE="${DELEGATE_OTHER_PROVIDER_ERROR_GRACE:-90}"
POLL_SECS="${DELEGATE_POLL_SECS:-2}"

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
guidance_dir="${DELEGATE_GUIDANCE_DIR:-}"
no_guidance=0
k=1
keep_candidates=0

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
    --guidance)    [ $# -ge 2 ] || die_usage "$1 needs a value"; guidance_dir="$2"; shift 2 ;;
    --no-guidance) no_guidance=1; shift ;;
    --k)           [ $# -ge 2 ] || die_usage "$1 needs a value"; k="$2"; shift 2 ;;
    --keep-candidates) keep_candidates=1; shift ;;
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
for n in "$timeout_secs" "$idle_secs" "$max_text" "$k"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die_usage "expected a positive integer, got '$n'"
done
if [ -n "$worktree" ] && ! [[ "$worktree" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die_usage "worktree name may only contain letters, digits, '.', '_' and '-'"
fi
command -v jq >/dev/null 2>&1 || die_usage "jq is required"

[ -n "${models//[[:space:],]/}" ] || die_usage "no models given"

# parse_entry ENTRY: sets ent_harness and ent_model.
parse_entry() {
  local e="$1" prefix
  ent_harness="opencode"; ent_model="$e"
  if [[ "$e" == *:* ]]; then
    prefix="${e%%:*}"
    if [[ " $HARNESSES " == *" $prefix "* ]]; then
      ent_harness="$prefix"; ent_model="${e#*:}"
    elif [[ "$prefix" =~ ^[a-z]+$ ]]; then
      die_usage "unknown harness '$prefix' in '$e' (one of: $HARNESSES)"
    fi
  fi
  if [ "$ent_harness" = opencode ] && [ -n "$ent_model" ] && [[ "$ent_model" != */* ]]; then
    ent_model="opencode/$ent_model"
  fi
}

# Check every entry before anything runs, so a typo late in the chain is a
# usage error up front, not an exit after earlier attempts already ran.
IFS=',' read -r -a model_list <<< "$models"
for raw_entry in "${model_list[@]}"; do
  entry="$(echo "$raw_entry" | tr -d '[:space:]')"
  [ -n "$entry" ] && parse_entry "$entry"
done
command -v setsid >/dev/null 2>&1 || die_usage "setsid is required"
if [ -n "$guidance_dir" ]; then
  [ -d "$guidance_dir" ] || die_usage "guidance directory $guidance_dir not found"
  guidance_dir="$(cd "$guidance_dir" && pwd)"
fi

if [ -n "$workdir" ]; then
  cd "$workdir" || die_usage "cannot cd to $workdir"
fi

# ── Best of K ────────────────────────────────────────────────────────────────
# Run K copies of this script in parallel, each in its own worktree and each
# starting its fallback chain at a different entry (so candidates use
# different workers when the chain has enough entries), then keep one.
# Selection: a candidate whose status is ok (its --check passed, if given)
# beats one that is not; then one that changed something beats one that
# changed nothing (an "ok" with an empty diff did not do the task, and
# without a --check nothing else catches it); then the smallest diff (lines
# added plus removed) wins, then the earliest candidate.
if [ "$k" -gt 1 ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die_usage "--k needs a git repository"
  [ -n "$worktree" ] || worktree="cand-$(date +%Y%m%d%H%M%S)"
  base_rev="$(git rev-parse HEAD)" || die_usage "--k needs a commit to start from"
  for ((c = 1; c <= k; c++)); do
    [ ! -e "$top/.delegate/$worktree-$c" ] || die_usage "$top/.delegate/$worktree-$c already exists"
  done
  run_id="$(date +%Y%m%d-%H%M%S)-$$"
  log_root="${DELEGATE_LOG_DIR:-${TMPDIR:-/tmp}/delegate}/$run_id"
  mkdir -p "$log_root"
  printf '%s' "$spec" > "$log_root/spec.txt"
  entries=()
  for raw_entry in "${model_list[@]}"; do
    entry="$(echo "$raw_entry" | tr -d '[:space:]')"
    [ -n "$entry" ] && entries+=("$entry")
  done
  common=(-t "$timeout_secs" --idle "$idle_secs" --max-text "$max_text" --spec-file "$log_root/spec.txt")
  [ -n "$check_cmd" ] && common+=(--check "$check_cmd")
  [ "$raw" -eq 1 ] && common+=(--raw)
  [ "$no_guidance" -eq 1 ] && common+=(--no-guidance)
  [ -n "$guidance_dir" ] && common+=(--guidance "$guidance_dir")
  pids=()
  for ((c = 1; c <= k; c++)); do
    n=${#entries[@]}; off=$(( (c - 1) % n )); chain=""
    for ((j = 0; j < n; j++)); do
      chain+="${chain:+,}${entries[$(( (off + j) % n ))]}"
    done
    DELEGATE_LOG_DIR="$log_root/candidates" "${BASH_SOURCE[0]}" "${common[@]}" -m "$chain" -w "$worktree-$c" \
      > "$log_root/candidate-$c.json" 2> "$log_root/candidate-$c.log" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  candidates="[]"; best=0; best_ok=0; best_size=0; best_rank=0
  for ((c = 1; c <= k; c++)); do
    res="$log_root/candidate-$c.json"
    if ! jq -e . "$res" >/dev/null 2>&1; then
      echo '{"status":"failed","attempts":[],"report":"candidate produced no result; see its log"}' > "$res"
    fi
    st="$(jq -r .status "$res")"
    cm="$(jq -r '.commit // empty' "$res")"
    size=0
    if [ -n "$cm" ]; then
      size="$(git diff --numstat "$base_rev" "$cm" 2>/dev/null | awk '{a += $1 + $2} END {print a + 0}')"
    fi
    candidates="$(jq -c --argjson c "$c" --argjson size "$size" --arg w "$worktree-$c" --slurpfile r "$res" \
      '. + [{candidate: $c, worktree: $w, status: $r[0].status, harness: $r[0].harness, model: $r[0].model,
             branch: $r[0].branch, commit: $r[0].commit, diff_lines: $size,
             check_exit: ($r[0].check.exit // null)}]' <<< "$candidates")"
    ok=0; [ "$st" = ok ] && ok=1
    # rank: 2 = ok with changes, 1 = ok without, 0 = not ok
    rank=0; [ "$ok" -eq 1 ] && rank=1; [ "$ok" -eq 1 ] && [ "$size" -gt 0 ] && rank=2
    if [ "$best" -eq 0 ] || [ "$rank" -gt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [ "$rank" -eq 2 ] && [ "$size" -lt "$best_size" ]; }; then
      best=$c; best_ok=$ok; best_size=$size; best_rank=$rank
    fi
  done
  [ "$best_ok" -eq 1 ] || best=0

  if [ "$keep_candidates" -eq 0 ]; then
    for ((c = 1; c <= k; c++)); do
      [ "$c" -eq "$best" ] && continue
      git worktree remove --force "$top/.delegate/$worktree-$c" >/dev/null 2>&1
      git branch -D "delegate/$worktree-$c" >/dev/null 2>&1
    done
  fi

  if [ "$best" -gt 0 ]; then
    jq --argjson cands "$candidates" --argjson sel "$best" --argjson kept "$keep_candidates" \
      '. + {selected: $sel, candidates: $cands, candidates_kept: ($kept == 1)}' "$log_root/candidate-$best.json"
    exit 0
  fi
  jq -n --argjson cands "$candidates" --argjson kept "$keep_candidates" --arg logs "$log_root" \
    '{status: "failed", selected: null, candidates: $cands, candidates_kept: ($kept == 1), logs: $logs,
      report: "no candidate succeeded"}'
  exit 1
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
home_root="${DELEGATE_HOME:-$HOME/.cache/cloud-agents/delegate}"
mkdir -p "$home_root"

# ── Worker guidance (Harness2-style "harness" files, docs/delegation.md) ─────
# A committed .delegate-guidance/ in the repository: AGENTS.md goes into the
# prompt as is; skills are listed for the worker to read when relevant, so
# nothing is written into the worker's tree and every harness CLI handles it
# the same way.
guidance_json="null"
guidance_block=""
if [ "$raw" -eq 0 ] && [ "$no_guidance" -eq 0 ]; then
  if [ -z "$guidance_dir" ] && [ "$in_git" -eq 1 ]; then
    candidate_dir="$(git rev-parse --show-toplevel)/.delegate-guidance"
    [ -d "$candidate_dir" ] && guidance_dir="$candidate_dir"
  fi
fi
if [ -n "$guidance_dir" ] && [ "$raw" -eq 0 ] && [ "$no_guidance" -eq 0 ]; then
  case "$guidance_dir/" in
    "$workdir"/*) shown_dir="${guidance_dir#"$workdir"/}" ;;
    *)            shown_dir="$guidance_dir" ;;
  esac
  [ "$guidance_dir" = "$workdir" ] && shown_dir="."
  agents_chars=0
  if [ -s "$guidance_dir/AGENTS.md" ]; then
    agents_text="$(cat "$guidance_dir/AGENTS.md")"
    agents_chars=${#agents_text}
    if [ "$agents_chars" -gt "${DELEGATE_GUIDANCE_MAX:-16000}" ]; then
      agents_text="${agents_text:0:${DELEGATE_GUIDANCE_MAX:-16000}}
[truncated; the rest is in $shown_dir/AGENTS.md]"
    fi
    guidance_block+="Project guidance (from $shown_dir/AGENTS.md):
$agents_text

"
  fi
  skills_list=""
  skill_names="[]"
  for f in "$guidance_dir"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    sname="$(sed -n '/^---$/,/^---$/{s/^name:[[:space:]]*//p}' "$f" | head -1)"
    sdesc="$(sed -n '/^---$/,/^---$/{s/^description:[[:space:]]*//p}' "$f" | head -1)"
    [ -n "$sname" ] || sname="$(basename "$(dirname "$f")")"
    skills_list+="- $sname: $sdesc ($shown_dir/skills/$(basename "$(dirname "$f")")/SKILL.md)
"
    skill_names="$(jq -c --arg n "$sname" '. + [$n]' <<< "$skill_names")"
  done
  if [ -n "$skills_list" ]; then
    guidance_block+="Guidance files: before starting, read the ones that apply to this task.
$skills_list
"
  fi
  guidance_json="$(jq -n -c --arg d "$guidance_dir" --argjson a "$agents_chars" --argjson s "$skill_names" \
    '{dir: $d, agents_md_chars: $a, skills: $s}')"
fi

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

${guidance_block}Task:
$spec"
fi

# Base environment for every worker and for --check: nothing the session
# holds beyond what any process needs. Per-harness credentials are added in
# prepare_harness. ~/.local/bin is on PATH for on-demand installs.
worker_path="$PATH"
case ":$worker_path:" in *":$HOME/.local/bin:"*) ;; *) worker_path="$worker_path:$HOME/.local/bin" ;; esac
base_env=(
  "PATH=$worker_path"
  "LANG=${LANG:-C.UTF-8}"
  "TERM=dumb"
  "TMPDIR=${TMPDIR:-/tmp}"
)
for v in USER LC_ALL NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR \
         HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
         ${DELEGATE_PASS_ENV:-}; do
  if [ -n "${!v:-}" ]; then
    base_env+=("$v=${!v}")
  fi
done
mkdir -p "$home_root/check"
check_env=("${base_env[@]}" "HOME=$home_root/check")

# pass_env NAME...: add each set variable to env_for.
pass_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] && env_for+=("$v=${!v}")
  done
  return 0
}

# write_login DEST JSON FIELD-JQ: install a vault login file unless the one
# already on the home volume is at least as new (by FIELD, compared as numbers
# when both are numbers, else as strings). CLIs refresh these files in place
# and refresh tokens rotate, so an older vault copy must never win.
write_login() {
  local dest="$1" json="$2" field="$3" new old
  new="$(jq -er "$field // empty" <<< "$json" 2>/dev/null)" || {
    echo "delegate-task: ignoring ${dest##*/} from the vault: not valid JSON or missing $field" >&2
    return 1
  }
  if [ -L "$dest" ] && [ ! -e "$dest" ]; then rm -f "$dest"; fi
  if [ -s "$dest" ]; then
    old="$(jq -er "$field // empty" "$dest" 2>/dev/null || true)"
    if [[ "$new" =~ ^[0-9]+$ && "$old" =~ ^[0-9]+$ ]]; then
      [ "$new" -gt "$old" ] || return 0
    elif [ -n "$old" ] && ! [[ "$new" > "$old" ]]; then
      return 0
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  ( umask 077; printf '%s\n' "$json" > "$dest.tmp.$$" ) && mv -f "$dest.tmp.$$" "$dest"
}

# prepare_harness H MODEL: sets env_for (the worker environment) and auth_mode
# (subscription|api_key|free|none) for one attempt.
prepare_harness() {
  local h="$1" model="$2" wh="$home_root/$1"
  mkdir -p "$wh"
  env_for=("${base_env[@]}" "HOME=$wh")
  auth_mode="none"
  case "$h" in
    claude)
      local src="$HOME/.claude/.credentials.json" dest="$wh/.claude/.credentials.json"
      if [ "$wh" != "$HOME" ] && [ -f "$src" ] && [ ! "$src" -ef "$dest" ]; then
        # Linked so a token refresh by either process is seen by both.
        mkdir -p "$wh/.claude"; ln -sfn "$src" "$dest"; auth_mode="subscription"
        claude_linked_src="$src"
      elif [ "$wh" != "$HOME" ] && [ -f "$src" ]; then
        auth_mode="subscription"; claude_linked_src="$src"
      elif [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ] && write_login "$dest" "$CLAUDE_CREDENTIALS_JSON" '.claudeAiOauth.expiresAt'; then
        auth_mode="subscription"
      elif [ -s "$dest" ]; then
        auth_mode="subscription"
      elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        pass_env CLAUDE_CODE_OAUTH_TOKEN; auth_mode="subscription"
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        pass_env ANTHROPIC_API_KEY; auth_mode="api_key"
      fi
      ;;
    codex)
      env_for+=("CODEX_HOME=$wh/.codex")
      mkdir -p "$wh/.codex"
      if [ -n "${CODEX_AUTH_JSON:-}" ]; then
        write_login "$wh/.codex/auth.json" "$CODEX_AUTH_JSON" '.last_refresh' || true
      fi
      if [ -s "$wh/.codex/auth.json" ]; then
        auth_mode="subscription"
      elif [ -n "${CODEX_API_KEY:-${OPENAI_API_KEY:-}}" ]; then
        env_for+=("CODEX_API_KEY=${CODEX_API_KEY:-$OPENAI_API_KEY}")
        pass_env OPENAI_API_KEY; auth_mode="api_key"
      fi
      ;;
    gemini)
      if [ -n "${GEMINI_OAUTH_CREDS_JSON:-}" ]; then
        write_login "$wh/.gemini/oauth_creds.json" "$GEMINI_OAUTH_CREDS_JSON" '.expiry_date' || true
      fi
      if [ -s "$wh/.gemini/oauth_creds.json" ]; then
        # Headless gemini picks its auth type from the environment.
        env_for+=("GOOGLE_GENAI_USE_GCA=true"); auth_mode="subscription"
      elif [ -n "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ]; then
        env_for+=("GEMINI_API_KEY=${GEMINI_API_KEY:-$GOOGLE_API_KEY}"); auth_mode="api_key"
      fi
      pass_env GOOGLE_CLOUD_PROJECT
      ;;
    opencode)
      # shellcheck disable=SC2086
      pass_env $OPENCODE_KEYS
      if [[ "$model" == opencode/* ]] && [ -z "${OPENCODE_ZEN_API_KEY:-${OPENCODE_API_KEY:-}}" ]; then
        # The free models need some key value; the opencode harness's
        # entrypoint uses the same placeholder.
        env_for+=("OPENCODE_ZEN_API_KEY=free-model-placeholder"); auth_mode="free"
      else
        auth_mode="api_key"
      fi
      ;;
  esac
}

# A CLI that refreshes its login by writing a new file and renaming it into
# place replaces the link with a regular file, leaving the newly rotated
# refresh token only in the worker's copy and the session's own copy holding
# a dead one. After a claude attempt, copy a newer worker login back over the
# session's file and restore the link.
sync_claude_login() {
  local src="$1" dest="$home_root/claude/.claude/.credentials.json" new old
  [ -n "$src" ] && [ -f "$src" ] || return 0
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    new="$(jq -er '.claudeAiOauth.expiresAt // empty' "$dest" 2>/dev/null || echo 0)"
    old="$(jq -er '.claudeAiOauth.expiresAt // empty' "$src" 2>/dev/null || echo 0)"
    # Only a complete login may replace the session's: a newer but corrupt
    # file would break the session's own login.
    if [[ "$new" =~ ^[0-9]+$ && "$old" =~ ^[0-9]+$ ]] && [ "$new" -gt "$old" ] &&
       jq -e '(.claudeAiOauth.accessToken | type == "string" and length > 0) and
              (.claudeAiOauth.refreshToken | type == "string" and length > 0)' "$dest" >/dev/null 2>&1; then
      ( umask 077; cp "$dest" "$src.tmp.$$" ) && mv -f "$src.tmp.$$" "$src"
    fi
  fi
  ln -sfn "$src" "$dest"
}

# worker_bin H: path of the harness CLI. DELEGATE_<HARNESS>_BIN overrides
# (tests use it); then the image's own copy (on PATH, outside $HOME); then the
# managed install described in the header, installed or refreshed here.
worker_bin() {
  local h="$1" var p dir bin stamp now failed
  var="DELEGATE_$(echo "$h" | tr '[:lower:]' '[:upper:]')_BIN"
  if [ -n "${!var:-}" ]; then echo "${!var}"; return 0; fi
  p="$(command -v "$h" 2>/dev/null || true)"
  if [ -n "$p" ] && [[ "$p" != "$HOME"/* ]]; then echo "$p"; return 0; fi
  dir="$HOME/.cache/cloud-agents/delegate-cli/$h"
  bin="$dir/bin/$h"
  failed="$HOME/.cache/cloud-agents/delegate-cli/.$h.failed"
  cli_fresh() {
    [ -x "$bin" ] && stamp="$(cat "$dir/.installed" 2>/dev/null)" && [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    [ $(( now - stamp )) -lt $(( ${DELEGATE_REFRESH_DAYS:-7} * 86400 )) ]
  }
  # recently_failed: an install attempt failed within the retry window
  # (DELEGATE_INSTALL_RETRY_SECS, default an hour). Without it, every
  # delegation would wait out another failing install (offline, registry
  # outage) before using the old install or giving up.
  recently_failed() {
    local t
    t="$(cat "$failed" 2>/dev/null)" && [[ "$t" =~ ^[0-9]+$ ]] || return 1
    [ $(( $(date +%s) - t )) -lt "${DELEGATE_INSTALL_RETRY_SECS:-3600}" ]
  }
  if cli_fresh; then echo "$bin"; return 0; fi
  if recently_failed; then
    [ -x "$bin" ] && { echo "$bin"; return 0; }
    return 1
  fi
  if [ "${DELEGATE_AUTO_INSTALL:-1}" = "0" ]; then
    [ -x "$bin" ] && { echo "$bin"; return 0; }
    return 1
  fi
  # Parallel delegations (background worktrees) must not install the same CLI
  # at once; the second waits, then finds it fresh.
  mkdir -p "$HOME/.cache/cloud-agents/delegate-cli"
  exec 8> "$HOME/.cache/cloud-agents/delegate-cli/.install.lock" || return 1
  flock -w "$(( ${DELEGATE_INSTALL_TIMEOUT:-300} + 30 ))" 8 || { exec 8>&-; return 1; }
  if cli_fresh; then exec 8>&-; echo "$bin"; return 0; fi
  if recently_failed; then exec 8>&-; [ -x "$bin" ] && { echo "$bin"; return 0; }; return 1; fi
  echo "delegate-task: installing the newest $h CLI (log: $log_root/install-$h.log)" >&2
  # Into a new versioned prefix; the $dir symlink moves to it only once it has
  # passed the check, so a failed refresh leaves the previous install in use,
  # and a delegation still running the previous one keeps its files (they are
  # pruned a day later). Bounded, and with the scrubbed environment: a
  # package's install scripts get no more of the session's credentials than a
  # worker does.
  local new
  new="$dir-$(date +%s)"
  if timeout --kill-after=10 "${DELEGATE_INSTALL_TIMEOUT:-300}" env -i "${base_env[@]}" "HOME=$HOME" \
       "$script_dir/install-harness-cli.sh" --prefix "$new" "$h" > "$log_root/install-$h.log" 2>&1 8>&- \
     && [ -x "$new/bin/$h" ]; then
    date +%s > "$new/.installed"
    # Restart the superseded install's day before it is pruned.
    [ -L "$dir" ] && touch "$(readlink -f "$dir")" 2>/dev/null
    ln -sfn "$new" "$dir.tmp" && mv -Tf "$dir.tmp" "$dir"
    find "$(dirname "$dir")" -maxdepth 1 -name "$h-*" ! -path "$new" -mmin +1440 -exec rm -rf {} + 2>/dev/null
    rm -f "$failed"
  else
    rm -rf "$new"
    date +%s > "$failed"
    echo "delegate-task: installing $h failed; see $log_root/install-$h.log" >&2
  fi
  exec 8>&-
  [ -x "$bin" ] || return 1
  echo "$bin"
}


# allowed H MODEL: whether CLOUD_AGENTS_DELEGATE_ALLOW permits this entry.
allowed() {
  local h="$1" m="$2" list="${CLOUD_AGENTS_DELEGATE_ALLOW:-}" pat ph pm short
  [ -n "${list//[[:space:],]/}" ] || return 0
  short="${m#opencode/}"
  IFS=',' read -r -a pats <<< "$list"
  for pat in "${pats[@]}"; do
    pat="$(echo "$pat" | tr -d '[:space:]')"
    [ -n "$pat" ] || continue
    ph="${pat%%:*}"
    [ "$ph" = "$h" ] || continue
    [[ "$pat" == *:* ]] || return 0
    pm="${pat#*:}"
    # shellcheck disable=SC2053
    if [[ "$m" == $pm || "$short" == $pm ]]; then return 0; fi
  done
  return 1
}

changed_files() {
  [ "$in_git" -eq 1 ] && git status --porcelain --untracked-files=all 2>/dev/null
}
# Content, not just the file list: a worker that edits a file the caller had
# already modified leaves `git status` unchanged.
# Outside git: the file list (adds and deletes) plus any file modified after
# the run started, using only stat calls so a large tree stays cheap.
start_marker="$log_root/.start"
: > "$start_marker"
tree_fingerprint() {
  if [ "$in_git" -eq 1 ]; then
    changed_files
    git diff HEAD 2>/dev/null | sha1sum
    git ls-files --others --exclude-standard -z 2>/dev/null | xargs -0 -r sha1sum 2>/dev/null
  else
    find . -type f -print 2>/dev/null | LC_ALL=C sort | sha1sum
    find . -type f -newer "$start_marker" -print 2>/dev/null | LC_ALL=C sort
  fi
}
start_fingerprint="$(tree_fingerprint)"

# The worker command for harness H and MODEL ("" = the CLI's default).
build_cmd() {
  local h="$1" model="$2" bin="$3" lastmsg="$4"
  local -a m=()
  [ -n "$model" ] && m=(--model "$model")
  case "$h" in
    opencode) cmd=("$bin" run --print-logs "${m[@]}" --format json -- "$prompt") ;;
    claude)   cmd=("$bin" -p --output-format stream-json --verbose --dangerously-skip-permissions "${m[@]}" -- "$prompt") ;;
    codex)    cmd=("$bin" exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -o "$lastmsg" "${m[@]}" -- "$prompt") ;;
    gemini)   cmd=("$bin" --yolo --output-format stream-json "${m[@]}" --prompt "$prompt") ;;
  esac
}

# stderr lines that mean the provider is refusing work (the attempt is then
# abandoned if no output follows within the grace period).
provider_error_pattern() {
  case "$1" in
    opencode) echo 'level=ERROR.*small=false' ;;
    *)        echo '[Rr]ate.?limit|RESOURCE_EXHAUSTED|(^|[^0-9])429([^0-9]|$)|[Oo]verloaded|[Qq]uota' ;;
  esac
}

# Whether the attempt's output shows a successful finish, per harness.
succeeded() {
  local h="$1" out="$2" lastmsg="$3"
  case "$h" in
    opencode) jq -e -s 'map(select(.type=="step_finish")) | last | .part.reason == "stop"' "$out" >/dev/null 2>&1 ;;
    claude)   jq -e -s 'map(select(.type=="result")) | last | (.subtype == "success" and (.is_error | not))' "$out" >/dev/null 2>&1 ;;
    codex)    jq -e -s '(map(select(.type=="turn.completed")) | length > 0) and (map(select(.type=="turn.failed")) | length == 0)' "$out" >/dev/null 2>&1 ;;
    gemini)   jq -e -s 'map(select(.type=="result")) | last | .status == "success"' "$out" >/dev/null 2>&1 ;;
  esac
}

# Runs one attempt; sets attempt_outcome to ok|timeout|idle|provider_error|
# exit_<n>|incomplete.
run_attempt() {
  local h="$1" model="$2" bin="$3" out="$4" err="$5" lastmsg="$6"
  local pattern grace="$PROVIDER_ERROR_GRACE"
  pattern="$(provider_error_pattern "$h")"
  [ "$h" = opencode ] || grace="$OTHER_PROVIDER_ERROR_GRACE"
  build_cmd "$h" "$model" "$bin" "$lastmsg"

  : > "$out"; : > "$err"; rm -f "$lastmsg"
  # Its own session and process group, so a kill also reaches the build and
  # test commands the worker started; otherwise they would keep running (and
  # editing) while the next model works.
  setsid env -i "${env_for[@]}" "${cmd[@]}" < /dev/null > "$out" 2> "$err" &
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
    err_count=$(grep -cE "$pattern" "$err" 2>/dev/null)
    if [ "${err_count:-0}" -gt "$err_seen" ]; then
      err_seen=$err_count; error_at=$now
    fi
    if [ $((now - start)) -ge "$timeout_secs" ]; then
      attempt_outcome="timeout"
    elif [ "$error_at" -gt 0 ] && [ "$last_change" -le "$error_at" ] && [ $((now - error_at)) -ge "$grace" ]; then
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
  elif succeeded "$h" "$out" "$lastmsg"; then
    attempt_outcome="ok"
  else
    attempt_outcome="incomplete"
  fi
}

# The last error line an attempt logged, for the attempts list.
last_error() {
  local h="$1" err="$2" out="$3"
  if [ "$h" = opencode ]; then
    grep -o 'error.error="[^"]*"' "$err" 2>/dev/null | tail -1 | sed 's/^error.error="//; s/"$//'
  else
    { jq -r 'select(.type=="error" or .type=="turn.failed") | (.message // .error.message // .error // empty) | tostring' "$out" 2>/dev/null
      grep -iE 'error|rate.?limit|quota|429' "$err" 2>/dev/null; } | tail -1 | cut -c1-300
  fi
}

attempts_json="[]"
final_status="failed"
final_model=""
final_harness=""
final_out=""
final_lastmsg=""
i=0
for raw_entry in "${model_list[@]}"; do
  entry="$(echo "$raw_entry" | tr -d '[:space:]')"
  [ -n "$entry" ] || continue
  parse_entry "$entry"
  h="$ent_harness"; model="$ent_model"
  i=$((i + 1))
  out="$log_root/attempt-$i.ndjson"
  err="$log_root/attempt-$i.log"
  lastmsg="$log_root/attempt-$i.last-message.txt"
  t0=$(date +%s)
  auth_mode=""
  if ! allowed "$h" "$model"; then
    attempt_outcome="not_allowed"; : > "$out"; : > "$err"
  elif ! bin="$(worker_bin "$h")"; then
    attempt_outcome="not_installed"; : > "$out"; : > "$err"
  else
    claude_linked_src=""
    prepare_harness "$h" "$model"
    run_attempt "$h" "$model" "$bin" "$out" "$err" "$lastmsg"
    [ "$h" = claude ] && sync_claude_login "$claude_linked_src"
  fi
  secs=$(( $(date +%s) - t0 ))
  provider_error=""
  [ "$attempt_outcome" = ok ] || provider_error="$(last_error "$h" "$err" "$out")"
  attempts_json="$(jq -c --arg h "$h" --arg m "$model" --arg o "$attempt_outcome" --argjson s "$secs" \
    --arg e "$provider_error" --arg a "$auth_mode" \
    '. + [{harness: $h, model: $m, outcome: $o, seconds: $s}
          + (if $a == "" then {} else {auth: $a} end)
          + (if $e == "" then {} else {last_error: $e} end)]' <<< "$attempts_json")"
  final_model="$model"
  final_harness="$h"
  final_out="$out"
  final_lastmsg="$lastmsg"
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
zero_usage='{"input":0,"output":0,"reasoning":0,"cache_read":0,"cost":0}'
usage_json="$zero_usage"
if [ -s "$final_out" ]; then
  case "$final_harness" in
    opencode)
      text_jq='map(select(.type=="text") | .part.text) | last // ""'
      usage_jq='map(select(.type=="step_finish") | .part) |
        {input: (map(.tokens.input // 0) | add // 0),
         output: (map(.tokens.output // 0) | add // 0),
         reasoning: (map(.tokens.reasoning // 0) | add // 0),
         cache_read: (map(.tokens.cache.read // 0) | add // 0),
         cost: (map(.cost // 0) | add // 0)}' ;;
    claude)
      text_jq='map(select(.type=="result")) | last | (.result // "") | if type == "string" then . else tostring end'
      usage_jq='map(select(.type=="result")) | last | {input: (.usage.input_tokens // 0),
         output: (.usage.output_tokens // 0), reasoning: 0,
         cache_read: (.usage.cache_read_input_tokens // 0), cost: (.total_cost_usd // 0)}' ;;
    codex)
      text_jq='map(select(.type=="item.completed" and .item.type=="agent_message") | .item.text) | last // ""'
      usage_jq='map(select(.type=="turn.completed") | .usage) |
        {input: (map(.input_tokens // 0) | add // 0),
         output: (map(.output_tokens // 0) | add // 0),
         reasoning: (map(.reasoning_output_tokens // 0) | add // 0),
         cache_read: (map(.cached_input_tokens // 0) | add // 0), cost: 0}' ;;
    gemini)
      text_jq='map(select(.type=="message" and .role=="assistant") | .content) | join("")'
      usage_jq='map(select(.type=="result")) | last | {input: (.stats.input_tokens // 0),
         output: (.stats.output_tokens // 0), reasoning: 0,
         cache_read: (.stats.cached // 0), cost: 0}' ;;
  esac
  final_text="$(jq -r -s "$text_jq" "$final_out" 2>/dev/null)"
  usage_json="$(jq -c -s "$usage_jq" "$final_out" 2>/dev/null)" || usage_json="$zero_usage"
  [ -n "$usage_json" ] && [ "$usage_json" != null ] || usage_json="$zero_usage"
fi
# codex writes its final message to a file (-o), which beats the event stream.
if [ "$final_harness" = codex ] && [ -s "$final_lastmsg" ]; then
  final_text="$(cat "$final_lastmsg")"
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
  # Worker-written tests can hang; bound the check like an attempt. GNU
  # timeout runs the command in its own process group and signals that whole
  # group, so this also stops anything the test started (no setsid here: it
  # would move the command out of that group).
  timeout --kill-after=5 "$timeout_secs" env -i "${check_env[@]}" bash -c "$check_cmd" > "$check_log" 2>&1
  check_rc=$?
  check_json="$(jq -n -c --arg c "$check_cmd" --argjson rc "$check_rc" --arg t "$(tail -c 1500 "$check_log")" \
    '{cmd: $c, exit: $rc, tail: $t}')"
  [ "$check_rc" -eq 0 ] || final_status="check_failed"
fi

commit=""
if [ -n "$branch" ] && [ "$final_status" = "ok" ] && [ -n "$changed" ]; then
  git add -A
  # Hooks off: .git/hooks is writable by the worker (same user) and a hook
  # would run here with the session's full environment.
  if git -c core.hooksPath=/dev/null -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo delegate-worker)}" \
         -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo delegate-worker@localhost)}" \
         commit -q -m "delegate($worktree): worker changes from $final_harness:$final_model" >&2; then
    commit="$(git rev-parse HEAD)"
  fi
fi

jq -n \
  --arg status "$final_status" \
  --arg model "$final_model" \
  --arg harness "$final_harness" \
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
  --argjson guidance "$guidance_json" \
  '{status: $status, harness: $harness, model: $model, attempts: $attempts, usage: $usage,
    report: $report, guidance: $guidance,
    changed: ($changed | split("\n") | map(select(length > 0))),
    diffstat: $diffstat, check: $check, workdir: $workdir, logs: $logs}
   + (if $branch == "" then {} else {branch: $branch, commit: (if $commit == "" then null else $commit end)} end)'

[ "$final_status" = "ok" ]
