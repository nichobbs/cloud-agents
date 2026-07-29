# Session visibility: todos, tool-run collapsing, highlights

Three features that make a long-running session legible from the UI,
added together (PR: session-ui-todo-tracking):

## 1. Session todo plan (three-state todos + panel)

`todos` gained a `status` column (`pending` / `in_progress` / `done`,
migration 0021); the legacy `done` flag is kept in lockstep so old readers
keep working. Three new shim MCP tools let the agent maintain its plan:

| Tool | Endpoint (container-auth) | Effect |
|------|---------------------------|--------|
| `add_todo` | `POST /api/sessions/{id}/callbacks/todos` | new `pending` item |
| `update_todo` | `POST /api/sessions/{id}/callbacks/todos/{tid}/status` | set status |
| `list_todos` | `GET /api/sessions/{id}/callbacks/todos` | full list |

These are session-scoped and distinct from `add_followup_task` (one-way
note to the human) and `add_task`/`list_tasks`/`complete_task` (repo-scoped
cross-session backlog). The user-facing counterpart is
`POST /api/todos/{tid}/status`.

The SessionDetail right column now has a **Todo panel**: live-polling
(4s while a run streams, 15s idle), click a status chip to cycle
pending → in progress → done, inline add/delete, link to the full page.

**Harnesses without the shim** (opencode/codex/gemini images have no
dotnet, so they can't run `cloud-agents-shim`): the instructions in
`docker/session-tools-guide.md` tell them to restate their plan as a
markdown checkbox list (`- [ ]` / `- [~]` / `- [x]`), and the panel
renders it read-only, parsed from the latest agent response
(`frontend/src/lib/agentPlan.ts`). This also picks up OpenCode's native
todo-list output when it renders as checkboxes.

## 2. Tool-run collapsing in the transcript

Runs of ≥2 consecutive shell/JSON blocks separated only by whitespace
collapse into a single row — "Ran 4 commands · used 2 tool calls" —
expandable to the individual (still individually collapsible) blocks.
Blocks with prose between them stay separate, because that prose is
context. Logic in `frontend/src/lib/blockGroups.ts` (unit-tested).

## 3. Highlights: surfacing what long responses bury

After each run, the backend can send the new agent messages to a cheap
or free summarizer model and extract *notable items* — discoveries,
issues opened/actioned/closed, workarounds, reverts, incomplete/skipped
work, follow-ups — into a `session_highlights` table, shown in a
**Highlights panel** (issues get their own section, each item deep-links
to its source message).

Configuration (env vars on the API server; feature off unless the URL
is set):

```
CLOUD_AGENTS_SUMMARIZER_URL    # OpenAI-compatible chat-completions endpoint,
                               # e.g. OpenCode Zen: https://opencode.ai/zen/v1/chat/completions
CLOUD_AGENTS_SUMMARIZER_MODEL  # default: big-pickle (OpenCode Zen free tier);
                               # any free/cheap model (e.g. a free DeepSeek) works
CLOUD_AGENTS_SUMMARIZER_KEY    # bearer token; falls back to OPENCODE_ZEN_API_KEY
```

Flow: the frontend POSTs `/api/sessions/{id}/highlights/refresh` when a
run finishes (and on the panel's Scan button). The handler scans up to 3
not-yet-scanned agent messages (16k-char tail each), asks the model for
`kind | title | detail` lines (deliberately NOT JSON — a line format
parses robustly), validates kinds against an allowlist, stores the
items, and advances a per-session scan cursor (`highlight_scans`) so
nothing is summarized twice. A transport failure leaves the cursor in
place for retry. The extraction prompt and parsing live in
`src/handlers/highlights.l` and are unit-tested without network.

Agents are also instructed (session-tools-guide) to end task responses
with a `## Session notes` section listing exactly these categories,
which makes the extraction reliable even with small models.

## Agent instruction plumbing

`docker/session-tools-guide.md` is rendered per harness by
`render_session_guide` in `docker/render-branch-policy.sh` (same
mechanism as the branch policy): Claude → `.claude/rules/`, OpenCode →
`.cloud-agents/` + `opencode.json` `instructions`, Gemini → appended
(marker-guarded) to the GEMINI.md we own, Codex → condensed prompt
prefix in `entrypoint-codex.sh`. Covered by
`scripts/test-branch-policy-inject.sh`.
