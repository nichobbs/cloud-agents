# Delegating work to other models and harnesses

Status: stage 1 built (`docker/delegate-task.sh`, the `delegate-to-worker` seed skill,
OpenCode in the claude image), extended so any harness can delegate to any other
(stage 1b). Stages 2 and 3 below are proposals.

## Why

A session on the claude harness usually runs Opus on the owner's Claude subscription.
The subscription is a usage allowance, so what matters is how many tokens Opus
processes. Most of an agent's tokens go on the inner loop: reading files, running
builds, re-reading errors, retrying. Delegation moves that loop to a cheaper or free
model and leaves Opus to write the spec and check the result.

Subscription logins are only meant for their vendor's own CLI: a Claude subscription
through Claude Code, a ChatGPT plan through Codex, a Google login through Gemini CLI. So
every worker runs through the matching harness CLI, never a third-party one, and the
orchestrator can be any harness. OpenCode adds Zen's free models (no key) and, with
keys, most other providers.

## Stage 1: `delegate-task` (built)

`docker/delegate-task.sh` is installed as `/usr/local/bin/delegate-task` in the claude
image, next to `opencode-ai` (same pin as `docker/Dockerfile.opencode`). It:

- runs `opencode run --format json --print-logs` with a worker preamble (no commits, no
  questions, run the named checks, end with a short report);
- works through a model fallback chain (`-m`, else `$DELEGATE_MODELS`, else a chain of
  free Zen models). It moves on when an attempt times out, goes idle, ends without a
  final `stop` step, or logs a provider error and makes no progress for 20s. That last
  case matters: on "Rate limit exceeded" `opencode run` keeps running instead of
  exiting;
- stops the chain with `failed_dirty` if a failed attempt already changed files, rather
  than letting the next model build on a half-finished edit;
- with `--check CMD`, runs the acceptance command itself and reports its exit code.
  The command runs code the worker wrote, so it gets the worker's scrubbed
  environment too;
- with `--worktree NAME`, works in `.delegate/NAME` on branch `delegate/NAME` and commits
  the result there, so several delegations can run in parallel;
- prints one JSON object (status, model, attempts, token usage, the worker's report,
  changed files, diffstat, check result, log directory). The orchestrator reads this,
  not the transcript.

The worker runs under `env -i` with only locale, proxy, CA and the model keys named in
`DELEGATE_PASS_ENV`. `CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_TOKEN` and the callback shim's
token are not in its environment, so a worker doing what it was asked will not push
(the git credential helper reads `GITHUB_TOKEN`) or reach the subscription. It has its
own `HOME` (`DELEGATE_HOME`, default under `$TMPDIR`). This is hygiene, not a security
boundary: the worker runs as the same OS user, so one that went looking could read the
session user's files and the environment of the session's own processes
(`/proc/<pid>/environ`), including those credentials. Treat a worker model as you would
any code you run in the session; real isolation is stage 3's separate container.

The `delegate-to-worker` seed skill tells the orchestrator when to delegate, how to
write a spec, and how to act on each status. Like every seed item it is only added to a
new user's library automatically; an existing user adds it from the library page.

Running `delegate-task` goes through the session's normal permission flow like any other
Bash command. It is not in the image's allow list, because approving it amounts to
approving whatever the worker does in the workspace.

Tests: `scripts/test-delegate-task.sh` (runs in CI) drives the script against a stub
`opencode` covering fallback, the dirty stop, the environment scrub, `--check`,
`--worktree` and usage errors.

### Measured so far (2026-10-19, from a Claude Code cloud container)

- With a working free model, a two-bug Python fix took 12 to 16s, about 36k to 45k
  worker tokens, and passed `--check`, on OpenCode 1.18.4 and 1.19.3.
- The free tier is unreliable from shared egress IPs. Of eleven free models, most
  returned "Rate limit exceeded" and one returned "free models aren't available from
  your current network because we've detected abusive traffic from this IP address".
  `nemotron-3.5-lightning-free` worked. A deployment on a VM with its own IP should do
  better, but plan for a paid fallback: an `OPENCODE_API_KEY` with a cheap Zen model
  (for example `deepseek-v4.1-flash` or `glm-5.3-flash`) at the end of
  `DELEGATE_MODELS`.
- Zen's free list changes every few weeks. The default chain is a starting point; set
  `DELEGATE_MODELS` per deployment or profile credential rather than editing the script.

### Still to measure

Whether delegation actually saves subscription usage. Run 10 or so real tasks both ways
(Opus alone, Opus delegating) and compare the orchestrator's tokens from the
stream-json `result` events, the worker success rate, and the number of rounds.
Expect the saving to be large for tightly specified tasks with a test command, and
small or negative for Lyric work, where free models have little training data and
failures cost Opus review rounds.

Also still to run live: codex and gemini as workers, with each kind of credential. The adapters are tested offline against stubs that emit the CLIs' real event
shapes, but no run has used real credentials yet.

## Stage 1b: any harness to any harness (built)

`delegate-task` ships in all five runner images and runs workers on four harnesses:

| Harness | Command | Success | Report | Usage |
|---|---|---|---|---|
| opencode | `opencode run --format json --print-logs` | last `step_finish` has `reason: stop` | last `text` part | `step_finish.tokens`, `cost` |
| claude | `claude -p --output-format stream-json --verbose --dangerously-skip-permissions` | last `result` has `subtype: success`, not `is_error` | `result.result` | `result.usage`, `total_cost_usd` |
| codex | `codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -o FILE` | a `turn.completed` and no `turn.failed` | the `-o` file | `turn.completed.usage` |
| gemini | `gemini --yolo --output-format stream-json --prompt` | last `result` has `status: success` | joined assistant `message` deltas | `result.stats` |

The event shapes were checked against the CLIs' own code at the pinned versions (Claude
Code 2.1.304, Codex 0.145.0, Gemini CLI 0.51.0) and the repo's live Claude fixtures.
The claude adapter has been run live on a subscription login: `claude:haiku` fixed a
two-bug Python file in 8s for $0.0024, the check passed, and the login was linked into
the worker's home rather than copied. The codex and gemini adapters have not been run
live yet, because that needs their credentials (see "Still to measure").

- **Chain entries** are `HARNESS:MODEL` (`codex:gpt-5.5`, `claude:sonnet`); `HARNESS:`
  uses the CLI's default model; an entry with no harness is an OpenCode model, as
  before.
- **Credentials.** A worker gets only its own harness's credentials, preferring a
  subscription login over an API key (the goal is to spend subscriptions):
  - claude: the session's `~/.claude/.credentials.json`, linked rather than copied so a
    token refresh by either process is seen by both; else `CLAUDE_CREDENTIALS_JSON` or
    `CLAUDE_CODE_OAUTH_TOKEN`; else `ANTHROPIC_API_KEY`.
  - codex: `CODEX_AUTH_JSON` (a ChatGPT login's `~/.codex/auth.json`) installed as
    `$CODEX_HOME/auth.json`; else `CODEX_API_KEY` / `OPENAI_API_KEY`.
  - gemini: `GEMINI_OAUTH_CREDS_JSON` (a Google login's `~/.gemini/oauth_creds.json`)
    with `GOOGLE_GENAI_USE_GCA=true`, which is how headless Gemini CLI selects a Google
    login; else `GEMINI_API_KEY` / `GOOGLE_API_KEY`.
  - opencode: Zen and provider keys; free models need none.

  `scripts/upload-credentials.sh` now uploads the two new logins when it finds them.
  Each worker harness has its own HOME on the home volume
  (`~/.cache/cloud-agents/delegate/<harness>`). A vault login is written there only when
  it is newer than the copy already there (by `last_refresh`, `expiry_date` or
  `expiresAt`), because the CLIs refresh these files in place and refresh tokens rotate:
  an older vault copy must not overwrite a refreshed one. Refreshed tokens are not
  written back to the vault (unlike the claude harness's own login,
  `writeBackClaudeLogin`), so on a fresh home volume an old vault copy may have expired
  and need re-uploading.
- **Profile limits.** `CLOUD_AGENTS_DELEGATE_ALLOW` is a comma-separated list of
  `HARNESS` or `HARNESS:MODEL-GLOB` patterns (`opencode:*-free,codex:gpt-5*,claude`).
  Entries matching none are skipped as `not_allowed`. Like the environment scrub, this
  steers a cooperating agent rather than enforcing a boundary: the agent could run a
  CLI itself.
- **On-demand install.** A missing CLI is installed with
  `npm install -g --prefix ~/.local` at the image's pinned version on first use, and
  stays on the home volume. It is reported as `not_installed` if that fails or
  `DELEGATE_AUTO_INSTALL=0`.

## Stage 2: a `delegate_task` tool (proposal)

Expose the same behaviour as a shim tool, so the server sees each delegation. That
gives a per-profile model allowlist and budget, ledger entries for each delegation,
and usage in the session panel. The shim would run the worker through `Std.Process`
with the same environment scrub.

## Stage 3: delegation to separate sessions (proposal)

`spawn_session` / `get_session_result` / `send_session_message` shim tools, built on
the observer's host-side path (`ensureObserverSession`, `runSessionMessageBlocking`):
each worker gets its own container, workspace and branch, and results come back
through git. Needs hard limits on depth, count and cost, and children must inherit the
profile's credential and network rules without widening them. Worth building only if
stage 1 shows real savings and the single container becomes the bottleneck.

## Why not one image with every harness

The five per-harness images stay. Every image carries `delegate-task`, the claude image
also carries OpenCode, and any other worker CLI is installed into `~/.local` on first use
and kept on the home volume. Merging all harnesses into one image would couple their
version pins (one broken npm release, as happened on the first unpinned sibling image,
would break every harness), grow every session's image, and put every CLI's credentials
handling in every container, for no gain over this arrangement.
