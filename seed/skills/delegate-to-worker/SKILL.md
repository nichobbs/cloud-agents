---
name: delegate-to-worker
description: Hand well-specified coding tasks to a worker on another model or harness (claude, codex, gemini, opencode) with delegate-task, keeping your own context small, and verify the result yourself
---

Use this skill when `delegate-task` is on PATH (every runner image ships it) and a task
is concrete enough to hand off: a bug with a reproduction, a function to write against a
signature and tests, a mechanical refactor, a batch of similar edits. You stay the
orchestrator; a worker on another model or harness does the file reading, editing and
build-retry loop.
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

## Choosing a worker

Workers run on four harnesses, each with its own credentials. Name them in the chain as
`HARNESS:MODEL`:

| Harness | Example entry | Good for |
|---|---|---|
| `codex` | `codex:gpt-5.5` | focused code changes against tests |
| `claude` | `claude:sonnet`, `claude:haiku` | edits that need care with existing code |
| `gemini` | `gemini:gemini-3-flash` | reading and changing a lot of code at once |
| `opencode` | `opencode:big-pickle`, `opencode:deepseek-v4.1-flash` | free or cheap models for mechanical work |

- Prefer workers backed by a subscription login. Each attempt reports `auth`
  (`subscription`, `api_key` or `free`). Use the free OpenCode models as the first
  entries for simple work and a stronger worker as the fallback.
- Put alternatives in the chain rather than retrying by hand:
  `-m opencode:big-pickle,codex:gpt-5.5,claude:sonnet`.
- An attempt reported as `not_allowed` was excluded by the profile
  (`CLOUD_AGENTS_DELEGATE_ALLOW`). Use one that is allowed; don't run that harness's CLI
  directly to get around it.
- `not_installed` means the CLI was missing and could not be installed (no network, or
  `DELEGATE_AUTO_INSTALL=0`). Otherwise a missing CLI is installed on first use.

## Worker guidance

Cheap workers do much better with good standing instructions. Keep them in the
repository, in `.delegate-guidance/`, and commit them so worktrees get them too:

- `.delegate-guidance/AGENTS.md`: rules every worker should follow in this repo
  (build and test commands, conventions, things never to touch). It goes into every
  worker's prompt, so keep it short.
- `.delegate-guidance/skills/<name>/SKILL.md`: longer topic guides with `name` and
  `description` frontmatter, for example the language reference for a niche language.
  Workers are given the list and read the ones that apply.

When a delegation fails in a way better instructions would have prevented, and you can
point to the evidence (the failing check, the mistake in the diff), add that rule here
in the same change. Don't add rules you have no evidence for.

Use `--guidance DIR` for guidance kept elsewhere, and `--no-guidance` to leave it out.

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
- `-m a,b,c` sets the fallback chain (see above); the default comes from
  `$DELEGATE_MODELS`, else a chain of free OpenCode Zen models. An entry without a
  harness is an OpenCode model.
- `-t SECS` caps each attempt (default 900) and also the `--check` command.
- `--k N` runs N candidates in parallel, each in its own worktree and each starting
  from a different entry in the chain. It keeps one whose status is `ok`, preferring the
  smallest diff, and removes the others (`--keep-candidates` keeps them). Use it with a
  `--check` and with cheap or free workers: two or three tries cost little and raise the
  chance one passes. The result adds `selected` and a `candidates` summary.

The script prints one JSON object: `status` (`ok`, `failed`, `failed_dirty`,
`check_failed`), the `harness` and `model` that finished, `attempts` with each entry's
outcome and auth,
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
4. `failed` with every attempt showing `provider_error` or `exit_1`: the providers are
   rate limiting or blocking this network, or a login has run out of quota. Try another
   harness, a paid model (a provider key granted to the profile), or do the task
   yourself.

## Failure modes to avoid

- Pasting the worker's whole transcript or full diff into your own context.
- Delegating a vague task, then spending more effort correcting it than doing it.
- Trusting the worker's report that tests pass instead of the `check` result.
- Delegating secrets handling. The worker's environment is scrubbed of credentials, but
  it runs as the same OS user, so this is hygiene rather than isolation.
- Running the worker's code yourself (tests, scripts) before reading the diff. That runs
  it with your full session credentials; `--check` runs it with the scrubbed environment.
