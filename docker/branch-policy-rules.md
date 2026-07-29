# Branch Policy

Before making any code changes in this session, you MUST be on a working
branch — not the starting branch (e.g. `main`). If you are still on the
starting branch, rename it immediately before reading or editing any files.

## Creating a branch

Rename the current branch to a descriptive name:

    git branch -m <harness>/<short-description>

Where `<harness>` is the tool you are (claude, opencode, codex, or gemini)
and `<short-description>` summarizes the task from the initial prompt.

Examples:
- `claude/update-ci-files`
- `opencode/add-auth-feature`
- `codex/fix-sqlite-migration`
- `gemini/refactor-docker-entrypoint`

Use lowercase, hyphens only, 3-5 words max.

## Pushing

When you complete a task (or create a new branch for a new task), push the
branch to the remote:

    git push -u origin <branch-name>

This makes your work visible on GitHub. The remote is always `origin`.

## Multiple tasks

If you receive a new, unrelated task mid-session, create a new branch for
it. Push the previous branch first if you haven't already.

## Never work on the starting branch

The branch you were given (or that exists when the session starts) is the
starting point only. Always rename it before making changes. If you already
renamed it (or a fallback branch was created for you), skip this step.
