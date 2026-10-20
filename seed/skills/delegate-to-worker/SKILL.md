---
name: delegate-to-worker
description: Hand well-specified coding tasks to a cheaper worker model with delegate-task, keeping your own context small, and verify the result yourself
---

Use this skill when `delegate-task` is on PATH (the claude runner image ships it) and a
task is concrete enough to hand off: a bug with a reproduction, a function to write
against a signature and tests, a mechanical refactor, a batch of similar edits. You stay
the orchestrator; a cheaper model does the file reading, editing and build-retry loop.
The saving only exists if you do not read the worker's transcript, so work from the
JSON result and your own checks.

Do the work yourself instead when the task needs design judgement, touches security or
credentials, spans many loosely related files, or when writing the spec would take about
as long as the change.

## Writing the spec

The worker has none of your context. A good spec has:

- **Goal** in one or two sentences.
- **Files** to change, and files it must not touch.
- **Constraints**: language rules, conventions, APIs to use. For a niche language (for
  example Lyric), name the reference docs in the repo it must read first.
- **Acceptance**: the exact command that must pass, such as `npm test -- calc` or
  `lyric test`.

## Running it

```sh
delegate-task --check "<acceptance command>" --spec-file /tmp/spec.md
```

- `--worktree NAME` runs the worker in `.delegate/NAME` on branch `delegate/NAME` and
  commits its changes there. Use it for independent tasks you want to run in parallel
  (start each one in the background) or when you want to review before merging.
- Without `--worktree`, `changed` and `diffstat` are measured against `HEAD`, so they
  include your own uncommitted edits. Commit or stash first if you want to see only the
  worker's changes.
- `-m a,b,c` sets the model fallback chain; the default comes from `$DELEGATE_MODELS`,
  else a chain of free OpenCode Zen models. A bare id means `opencode/<id>`.
- `-t SECS` caps each attempt (default 900) and also the `--check` command.

The script prints one JSON object: `status` (`ok`, `failed`, `failed_dirty`,
`check_failed`), the `model` that finished, `attempts` with each model's outcome,
token `usage`, the worker's short `report`, `changed` files, `diffstat`, and the `check`
command's exit code and output tail. Full transcripts are under `logs`; read them only
to diagnose a failure.

## Checking the result

1. `ok` with a passing check: look at `diffstat` and read the diff of the files you care
   most about, not the whole change. Commit it yourself (workers never commit outside a
   worktree), or merge `delegate/NAME` and remove the worktree with
   `git worktree remove .delegate/NAME`.
2. `check_failed`: decide whether one more delegation with the failure output added to
   the spec is likely to fix it. If the same task fails twice, do it yourself.
3. `failed_dirty`: a worker left partial edits. Inspect them with `git diff`, then keep
   them or discard them before trying again. Nothing was reset for you.
4. `failed` with every attempt showing `provider_error` or `exit_1`: the free tier is
   rate limiting or blocking this network. Use a chain with a paid model (needs
   `OPENCODE_API_KEY` or a provider key granted to the profile), or do the task yourself.

## Failure modes to avoid

- Pasting the worker's whole transcript or full diff into your own context.
- Delegating a vague task, then spending more effort correcting it than doing it.
- Trusting the worker's report that tests pass instead of the `check` result.
- Delegating secrets handling. The worker's environment is scrubbed of credentials, but
  it runs as the same OS user, so this is hygiene rather than isolation.
- Running the worker's code yourself (tests, scripts) before reading the diff. That runs
  it with your full session credentials; `--check` runs it with the scrubbed environment.
