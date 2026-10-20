# Delegating work to cheaper models

Status: stage 1 built (`docker/delegate-task.sh`, the `delegate-to-worker` seed skill,
OpenCode in the claude image). Stages 2 and 3 below are proposals.

## Why

A session on the claude harness usually runs Opus on the owner's Claude subscription.
The subscription is a usage allowance, so what matters is how many tokens Opus
processes. Most of an agent's tokens go on the inner loop: reading files, running
builds, re-reading errors, retrying. Delegation moves that loop to a cheaper or free
model and leaves Opus to write the spec and check the result.

The orchestrator has to be Claude Code. Subscription credentials are only meant for
Claude Code, so Opus cannot run inside OpenCode on the subscription. The worker is the
OpenCode CLI, which reaches OpenCode Zen's free models without a key and, with keys,
most other providers (OpenAI, Gemini, DeepSeek and others through Zen).

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

The claude image now carries OpenCode as a worker, but the five per-harness images stay.
OpenCode reaches every provider the other harnesses do, so it is the only worker CLI the
orchestrator needs. Merging all harnesses into one image would couple their version
pins (one broken npm release, as happened on the first unpinned sibling image, would
break every harness), grow every session's image, and put every CLI's credentials
handling in every container, for no gain over this arrangement.
