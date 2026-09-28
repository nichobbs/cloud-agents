# Session Visibility

The human running this session does not read your full transcript. They
check in asynchronously on a phone or laptop and see the **session ledger**:
your work items, and the decisions, deviations, shortcuts, questions and
blockers you recorded. Anything not in the ledger is effectively invisible
to them. Do this for every non-trivial task.

## Session ledger

If the `cloud-agents` MCP server is available (its tools include
`ledger_get_state`):

- At the start of every run, and after any context compaction, call
  `ledger_get_state`. It returns your work items, what is waiting for review,
  and how much feedback the human has left.
- Know your unit of work. For a batch (a list of issues), call
  `ledger_register_items` once you know the list. For a single task,
  register one item: the issue (`#12`, `owner/repo#12`) or `local:<slug>`.
- Call `ledger_set_item_status` on every state change: `in_progress` when you
  start an item, `pr_open` / `done` when it is finished, `skipped` if you
  decide not to do it (with a reason).
- If you cannot work on an item because other work is needed first, set it
  to `blocked` with `blockedBy` (the issue refs it waits on) and/or
  `prerequisiteProposal` (the work needed first), plus your `recommendation`.
  Then move on to the next item. Do not stop the session. Use `needs_human`
  only when a person must decide or act before the item can continue.
- Record a decision (`ledger_record_decision`) whenever a reasonable reviewer
  might have chosen differently.
- Record a deviation (`ledger_record_deviation`) whenever you depart from the
  issue, spec or plan, or take a shortcut: skipping or weakening tests, stubs,
  TODOs, suppressed warnings, broad catch blocks. Be candid; unreported
  shortcuts are treated as more serious than reported ones.
- Always include a `recommendation` when you record something that needs
  review.
- Never wait for a reply. If you want input but can continue, use
  `ledger_ask` with the default you are proceeding with. Use `ask_user` only
  when you genuinely cannot continue without an answer.
- Call `ledger_check_feedback` before starting each new item, before opening
  a PR, and whenever a ledger tool's reply says feedback is waiting. Apply
  what it returns; if it changes your plan, record a decision that names the
  entry it revises in `supersedes`.
- Use `ledger_note` for anything the human should follow up on after the
  session (set `needsReview` when it needs their attention).

Use `report_progress` for a one-line live status at each milestone of a long
run. The human is notified automatically about blocked items and blocking
entries, so you do not also need `notify` for those.

If the ledger tools are NOT available, maintain your plan as a markdown
checkbox list restated at the END of each response — the UI parses it:

```
- [x] clone and build
- [~] fix the failing test    <- ~ means in progress
- [ ] push and open a PR
```

Use `- [ ]` pending, `- [~]` in progress, `- [x]` done, one item per line,
at least two items. Use `notify` (if available) when you finish or become
blocked.

## Surface the things humans miss

Long responses bury important facts. ALWAYS end your final response for a
task with a `## Session notes` section listing, as short bullets, any of
the following that occurred (omit the section only if truly none apply):

- Unexpected discoveries (bugs found, surprising behavior, config drift)
- Issues/tickets you opened, commented on, or closed — with number and URL
- Workarounds you applied instead of proper fixes
- Anything you reverted or undid
- Work left incomplete, skipped, or done as a shortcut, and why
- Follow-up work you recommend

Be factual and specific; these notes are extracted and shown to the human
in a dedicated panel, so vague bullets ("various fixes") are useless. When
the ledger tools are available, anything here that a reviewer should act on
belongs in the ledger as it happens, not only in this summary.
