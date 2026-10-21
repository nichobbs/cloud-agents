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
image, next to `opencode-ai` (installed as in `docker/Dockerfile.opencode`). It:

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

The event shapes were checked against the CLIs' own code (Claude Code 2.1.304, Codex
0.145.0, Gemini CLI 0.51.0) and the repo's live Claude fixtures. The images and on-demand
installs now take the newest release of each CLI that is at least a week old; see "CLI
versions" below.
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
    token refresh by either process is seen by both. If a refresh writes a new file and
    renames it over the link, the worker's copy is copied back over the session's file
    after the attempt, if it is newer, and the link is restored, so the session never
    keeps a rotated-out refresh token. Otherwise `CLAUDE_CREDENTIALS_JSON` or
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
  Entries matching none are skipped as `not_allowed`. The server sets it from the
  profile's "Delegation allowed to" field (`delegateAllow`, #1299); empty means no limit,
  and a deleted profile allows nothing. Like the environment scrub, this
  steers a cooperating agent rather than enforcing a boundary: the agent could run a
  CLI itself.
- **On-demand install.** A CLI the image doesn't ship is installed on first use into
  `~/.cache/cloud-agents/delegate-cli/<harness>` on the home volume, at the newest
  release that has passed the cool-down (see "CLI versions" below), and refreshed once it is `DELEGATE_REFRESH_DAYS`
  old (default 7). A refresh goes into a new versioned directory and only replaces
  the previous install once it has passed the check. After a failed install or
  refresh, delegations use the existing install, if any, without trying again for
  `DELEGATE_INSTALL_RETRY_SECS` (default an hour), so an offline session doesn't wait
  out a failing install every time. The attempt is reported as `not_installed` if no
  install is available or `DELEGATE_AUTO_INSTALL=0`.

### CLI versions

The runner images and the on-demand installs use the newest stable release of each
harness CLI and of uv that was published at least `HARNESS_CLI_MIN_AGE_DAYS` ago (default
7), not pinned versions. `docker/install-harness-cli.sh` picks it from the registry's
publish times (`npm view <package> time`, or PyPI for uv), skipping pre-releases and
anything above the registry's `latest` tag, installs it, and then
runs `docker/check-harness-cli.sh`, which checks that the CLI still accepts every flag
the entrypoints and `delegate-task` pass it (`codex exec --help`, `opencode run --help`
and so on). If the newest release fails the check, a warning is logged and the
known-good release listed in `install-harness-cli.sh` is installed instead; the same
happens if no release is old enough or the publish times can't be read. The image
build fails only if that fails too. A fallback rather than a failed build matters
because Coolify builds every image in one `docker compose build`, so one broken harness
image would also block the API deploy.

In the Dockerfiles, each install step is preceded by an `ADD` of the npm registry's
`latest` metadata (or uv's installer script). Docker re-fetches it on every build and
reruns the install only when it changes, that is, when a new version is published.
Without that, an unversioned install layer would stay cached indefinitely. Because the
rerun is triggered by a new release rather than by time passing, a release that clears
the cool-down is picked up at the first build after the package's next release (or
any uncached build). For these CLIs, which release several times a week, that is
little later.

`scripts/test-check-harness-cli.sh` (CI) fails if a launch line uses a flag the check
doesn't cover, or if an image still pins a version. The check would have caught two
bugs that shipped with pinned versions: `codex --full-auto --json` (fixed in #1310) and
`opencode run -q`. Limits: Claude Code's `--permission-prompt-tool` is hidden from its
help, so for that flag the check only confirms the name still appears in the installed
program. And a flag check can't catch a change in behaviour behind an unchanged flag.

**The cool-down (#1314).** These CLIs run with the session's credentials, and the flag
check guards against breaking releases, not a compromised one. A compromised npm or
PyPI release is usually caught and pulled within days, so a release only reaches the
images and the on-demand installs once it is `HARNESS_CLI_MIN_AGE_DAYS` old. Set it as a
Docker build argument (`--build-arg HARNESS_CLI_MIN_AGE_DAYS=3`; 0 takes the newest
release) or in a session's environment for `delegate-task`. Beyond the cool-down there
is no integrity check other than what npm and the uv installer do themselves.

## Stage 1c: worker guidance and best-of-K (built)

Two ideas taken from Harness2 (google-research/harness2, arXiv 2610.14224). There, a
strong model improves the "harness" (instructions, skills, guardrails) that cheap fixed
models work with, and keeps evidence-backed lessons per domain.

- **Worker guidance.** A repository can commit `.delegate-guidance/`.
  `AGENTS.md` there is put into every worker's prompt, before the task. Each
  `skills/<name>/SKILL.md` is listed by name, description and path for the worker to
  read when it applies. Nothing is written into the worker's tree, and every harness
  CLI handles it the same way. `--guidance DIR` uses another directory, `--no-guidance`
  and `--raw` leave it out, and `DELEGATE_GUIDANCE_MAX` (16000 characters) caps the
  inlined `AGENTS.md`. The skill tells the orchestrator to add a rule only when a
  failed delegation shows the need for it. That is Harness2's "evidence-supported
  lessons", kept in the repository where they can be reviewed with the code.
- **Best of K.** `--k N` runs N candidates in parallel, each in its own worktree
  (`NAME-1`..`NAME-N`) and each starting its chain at a different entry. A candidate
  with status `ok` (its `--check` passed, if given) wins over one without, then the
  smallest diff, then the earliest. The other worktrees and branches are removed unless
  `--keep-candidates` is set. This is Harness2's probe-and-compare step with a real
  check in place of behavioural contrast, which is cheap when the workers are free.

Live check: a repository whose `AGENTS.md` required a header line in every changed
Python file. `--k 2` with `opencode:nemotron-3.5-lightning-free` and `claude:haiku`
took 26s. Both candidates followed the rule and passed a check that tested for the
line, and the free one was kept on the tie.

Not taken from Harness2: its per-task improvement loop (proposing, probing and composing
harness edits with a strong model on every task). That spends orchestrator tokens on
every task, the opposite of this design's aim, and pays off only across many similar
tasks. It may be worth running occasionally over a batch of failed delegations.

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
