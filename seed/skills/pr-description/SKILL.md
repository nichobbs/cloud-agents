---
name: pr-description
description: Write a clear, reviewable pull request description with a summary and test plan
---

Use this skill whenever you are about to open a pull request.

## Structure

```markdown
## Summary
- 1-3 bullets on WHAT changed and WHY (the motivation, not a restatement of the diff)

## Test plan
- [ ] How you verified this works (commands run, scenarios exercised)
- [ ] Edge cases checked
- [ ] What you did NOT test, if anything relevant is out of scope
```

Add more sections only if the change needs them — a screenshot for a UI change, a
migration note for a schema change, a rollback plan for a risky change. Don't pad a
one-line fix with empty boilerplate sections.

## What makes a description reviewable

- Lead with *why*: what problem this solves or what it enables. The diff already shows
  what changed line-by-line; the description's job is the context a diff can't carry.
  "Fixes the race condition in X where Y" beats "Updates X.ts".
  Reference an issue number when one exists — but never invent one.
- The test plan must reflect verification you actually performed, not a checklist copied
  from a template and left unchecked. If you ran a build/test command, name it and its
  result. If you didn't test something, say so — a false "tested" is worse than an
  honest gap.
  If the repo has a PR template, populate its actual sections; don't append a redundant
  second summary/test-plan on top of it.
- Call out anything a reviewer should pay special attention to (a subtle edge case, a
  deliberate trade-off, a part you're unsure about) — don't bury it in the diff and hope
  it's noticed.
- Keep it proportional to the change. A one-line typo fix needs one line, not a
  five-section report.

## Failure modes to avoid

- A description that only repeats the commit list ("Updated file A. Updated file B.").
- Claiming something was tested/verified when it wasn't.
- Omitting a known limitation or follow-up because it's inconvenient to mention.
- Copy-pasted template boilerplate left unfilled (unchecked checkboxes, `[describe here]`
  placeholders).
