---
name: self-code-review
description: A pre-submit checklist to review your own diff before calling a task done
---

Use this skill after implementing a change and before declaring it finished — run it
against your own diff (`git diff`) as a reviewer would, not as the author who already
believes it's correct.

## Checklist

**Correctness**
- Does every branch (including error paths) do something sensible? Any off-by-one, null/
  undefined gap, or unreachable/dead branch?
- Does it actually solve the request, not an adjacent or partial version of it?

**Security** (skip sections that don't apply to this change)
- No hardcoded secrets, API keys, or credentials.
- User input is validated/sanitized before use in a query, shell command, or file path.
- No new injection surface (SQL, command, path traversal).

**Scope and simplicity**
- Is this the smallest change that solves the problem? Any unrequested refactors,
  abstractions for single-use logic, or "while I'm here" edits that broaden the diff?
- Does new code match the codebase's existing patterns (naming, error handling, module
  structure) rather than introducing a new style?

**Verification**
- Did you actually run the build/tests and see fresh output, not assume they'd pass?
- Any leftover debug code (console.log/print, commented-out blocks, TODO/HACK markers,
  debugger statements)?

**Tests**
- Is the changed behavior covered by a test? If a bug was fixed, is there a regression
  test for it?

## Output

State the verdict plainly: which checklist items you verified and how (command run,
file:line checked), and anything you're intentionally leaving out of scope. Fix what you
find before considering the task done — this is a gate, not a report to file away.

## Failure modes to avoid

- Rubber-stamping your own work because you just wrote it and it "looks right."
- Checking the box without actually running the verification command.
- Noticing an issue and deciding to mention it instead of fixing it, when fixing it is
  in scope.
