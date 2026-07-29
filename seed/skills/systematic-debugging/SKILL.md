---
name: systematic-debugging
description: A root-cause-first method for debugging failures instead of guessing at fixes
---

Use this skill when investigating a bug, test failure, or unexpected behavior — before
writing any fix.

## Method

1. **Reproduce first.** If you can't reliably reproduce it, you can't reliably confirm
   it's fixed. Find the smallest input/command that triggers it.
2. **Read the actual error completely.** The full stack trace, not just the last line.
   Note the exact file:line, the exact exception/assertion message, and what state led
   to it.
3. **Find the delta.** What changed recently that could cause this? `git log`/`git blame`
   on the relevant file(s). Compare a known-working case against the broken one — what's
   different between them?
4. **Form one hypothesis before reading more code.** State it explicitly: "I think X is
   happening because Y." A hypothesis you can prove or disprove is worth more than
   scanning code hoping something jumps out.
5. **Verify the hypothesis against the actual code and actual runtime behavior** — add a
   log line, run a debugger, or write a tiny reproduction script. Don't accept "seems
   plausible" as confirmation.
6. **Fix the root cause, not the symptom.** A null check that papers over an object being
   constructed wrong is a symptom fix; find out why it's null.
7. **Write or run a regression test** that would have caught this, when practical.
8. **Verify the fix against the original repro**, not just "it compiles now."

## The 3-failure circuit breaker

If three fix attempts in a row don't work, stop iterating on variations of the same
approach. That's a signal the mental model of the problem is wrong, not that the fourth
tweak will be the one. Step back and question the architecture/assumption instead.

## Failure modes to avoid

- Symptom chasing: adding a null check or try/catch around the crash site without
  understanding why the bad state occurred.
- Shotgun debugging: changing several things at once and hoping one of them helps — you
  won't know which change (if any) actually mattered.
- Skipping reproduction: attempting a fix for a bug you've only read about, not triggered
  yourself.
- Declaring victory without re-running the original failing case.
- Test-hacking: modifying a failing test to match broken behavior instead of fixing the
  behavior.
