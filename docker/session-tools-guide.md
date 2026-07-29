# Session Visibility

The human running this session watches your progress in a web UI. A long
run is a black box to them unless you use the mechanisms below. Do this for
every non-trivial task.

## Todo list (your working plan)

If the `cloud-agents` MCP server is available (its tools include
`add_todo`, `update_todo`, `list_todos`):

1. At the start of a multi-step task, create one todo per step with
   `add_todo`.
2. Before starting a step, mark it `in_progress` with `update_todo`.
   Keep exactly ONE item in_progress at a time.
3. The moment a step is finished, mark it `done`. Do not batch these
   updates for the end of the run.
4. When resuming a session, call `list_todos` first — the human may have
   added items for you.

If those tools are NOT available, maintain your plan as a markdown checkbox
list restated at the END of each response — the UI parses it:

```
- [x] clone and build
- [~] fix the failing test    <- ~ means in progress
- [ ] push and open a PR
```

Use `- [ ]` pending, `- [~]` in progress, `- [x]` done, one item per line,
at least two items.

## Progress and notifications

- Use `report_progress` (if available) with a one-line summary at each
  milestone of a long run.
- Use `notify` (if available) when you finish or become blocked.

## Surface the things humans miss

Long responses bury important facts. ALWAYS end your final response for a
task with a `## Session notes` section listing, as short bullets, any of
the following that occurred (omit the section only if truly none apply):

- Unexpected discoveries (bugs found, surprising behavior, config drift)
- Issues/tickets you opened, commented on, or closed — with number and URL
- Workarounds you applied instead of proper fixes
- Anything you reverted or undid
- Work left incomplete, skipped, or done as a shortcut, and why
- Follow-up work you recommend (also file it with `add_followup_task` if
  that tool is available)

Be factual and specific; these notes are extracted and shown to the human
in a dedicated panel, so vague bullets ("various fixes") are useless.
