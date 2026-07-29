---
name: conventional-commits
description: Write clear, conventional-format commit messages and split changes into atomic commits
---

Use this skill whenever you are about to run `git commit`.

## Message format

```
<type>(<optional scope>): <short summary, imperative mood, no trailing period>

<optional body: why this change, not what — the diff already shows what>

<optional footer: BREAKING CHANGE, issue references>
```

Types: `feat` (new capability), `fix` (bug fix), `refactor` (no behavior change), `test`,
`docs`, `perf`, `chore` (tooling/deps/build), `style` (formatting only).

- Summary line: under ~72 characters, imperative ("add", "fix", "remove" — not "added",
  "fixes", "removes").
- Body explains *why*, not *what*: the reviewer can read the diff; they can't read your
  reasoning for choosing this approach over another. Skip the body entirely for changes
  that are self-explanatory from the summary.
- Detect and match the project's existing convention first (`git log -20 --oneline`).
  If the project doesn't use `type(scope):` prefixes, don't introduce them unilaterally —
  match the house style instead of your default.

## Splitting into atomic commits

Before committing, check whether the staged changes span more than one concern
(`git status`, `git diff --stat`). Split when:

- Changes touch unrelated files/modules for different reasons (e.g. a dependency bump
  and a feature change).
- One part of the diff could be reverted independently without breaking the other.
- Config/build changes are mixed with logic changes.

Rule of thumb: 3+ files touching unrelated concerns → 2+ commits; 10+ files → don't
default to one commit just because it's less typing. Each commit should build and pass
tests on its own.

## Failure modes to avoid

- Vague summaries: "update stuff", "fix things", "wip". Say what changed.
- A body that restates the summary in more words instead of explaining the *why*.
- One giant commit mixing a refactor, a bug fix, and a new feature — impossible to
  bisect or revert cleanly.
- Never invent a scope or issue number that isn't real.
