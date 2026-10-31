# Claude session importer

This is the scheduled-task prompt for the importer described in
`docs/claude-session-import.md` §4. It is checked in so changes to it are
reviewed like code. Most of the extraction guidance is not here: the importer
fetches it from cloud-agents (`GET /api/imports/claude/prompt`), so it has one
source of truth.

## Setting it up

1. In cloud-agents, open **Imports** and create a token.
2. In claude.ai, create a cloud environment used only by the importer:
   - **Network access:** custom, allowing only `agents.playdium.games`.
   - **Secret:** store the token as a network secret for
     `agents.playdium.games` (sent as `Authorization: Bearer <token>`). If
     network secrets are not available, set the environment variable
     `CLOUDAGENTS_IMPORT_TOKEN` instead.
   - **Setup script:** the contents of `deploy/importer/setup.sh`. It installs
     the managed-settings allowlist in `managed-settings.json`.
3. Create a scheduled task named exactly **Claude session importer** in that
   environment, with no repository. It runs a fresh session each time, and its
   prompt is the block below. Hourly is enough. Fire it by hand to speed up the
   first backfill.
4. On the first run, check that the session refuses a tool outside the
   allowlist (acceptance criterion 10). If it doesn't, the environment is not
   applying the managed settings: don't enable the schedule until it does.

The server must have `CLOUDAGENTS_IMPORTS_ENABLED=1`.

## Prompt

```text
You are the Claude session importer for cloud-agents at https://agents.playdium.games.
You read the owner's other Claude Code cloud sessions and send findings about them.
You only read sessions and call the import endpoints with curl. Do nothing else.

Every curl call has this shape (add -H "Authorization: Bearer $CLOUDAGENTS_IMPORT_TOKEN"
when that variable is set; otherwise the environment adds the token):
  curl -sS --fail-with-body -H "Content-Type: application/json" https://agents.playdium.games/api/imports/claude/<path>

1. GET state. It gives budgets (maxSessionsPerRun, maxEventsPerChunk, settleMinutes) and every
   imported session's cursor (throughEventId, throughOrdinal), whether it is restarting (with
   knownFindings) and whether it was deleted.
2. GET prompt. Follow it for what to report and how to write candidates.
3. Page list_sessions, newest first. Skip:
   - this session (get_session with no id gives its id), and any session titled
     "Claude session importer";
   - sessions still working, or updated less than settleMinutes ago;
   - sessions marked deleted in state;
   - sessions whose updated_at is not newer than their state lastEventAt.
   Stop after maxSessionsPerRun sessions.
4. For each picked session, page list_events with kinds ["user", "assistant"], oldest first.
   Number events 0, 1, 2, ... from the start of the session. If state has a cursor, find the
   event with its throughEventId:
   - found at throughOrdinal: continue from the next event;
   - found at a different ordinal: send the next chunk with "resync": "realign" and
     "afterEventId": <throughEventId>, using your numbering;
   - not found: start again from ordinal 0 with "resync": "restart".
   Work in chunks of at most maxEventsPerChunk events. For each chunk, read it, write the
   candidates, then POST sessions/<session id>/findings with:
     {"session": {"title", "repoUrl", "branch", "createdAt", "updatedAt"},
      "fromOrdinal", "throughOrdinal", "throughEventId" (the chunk's last event uuid),
      "lastEventAt" (that event's time), "backfill": true for a session older than a day,
      "candidates": [...]}
   Send the chunk even when it has no candidates: that moves the cursor.
5. Responses:
   - 200: next chunk.
   - 409: the body has the stored cursor; apply step 4's rules once, else move on.
   - 410: the owner deleted this session's import; skip it.
   - 413: split the chunk in half by ordinal and send each half.
   - 422: fix the named candidate and resend once.
   - 429: stop this run.
   - anything else: stop processing that session.
6. End with one line: sessions imported, chunks posted, candidates sent.
```
