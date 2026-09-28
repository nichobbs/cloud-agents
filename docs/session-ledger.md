# Session ledger

Status: **Phases 1 and 2 implemented** (declared capture, live views, review
and feedback, cross-session inbox, repo severity policy). GitHub
reconciliation (Phase 3) and the undeclared-change observer (Phase 4) are
designed below and tracked as follow-ups, not built.

Source: the "Session Ledger: Architecture and Implementation Guide" spec,
adapted to this repository. That spec assumed a Cloudflare Workers + Hono +
KV app driving the Managed Agents API; cloud-agents is a Lyric/.NET service
that runs each message through a harness CLI in a one-shot Docker container.
§2 records how each assumption maps here and why.

## 1. Problem and goals

Agents report decisions, shortcuts, changes of direction and blockers only as
prose buried in a long transcript. In batch sessions (a list of issues) the
human also loses track of which items are done, blocked, and why.

The ledger captures those as structured entries plus per-item status in a
per-session ledger the human reviews **asynchronously** (typically from a
phone). The agent is never blocked waiting for review: feedback reaches it at
natural boundaries. The transcript stays available as evidence.

## 2. Recon: how the spec maps onto this repo

| Spec assumption | cloud-agents reality | Adaptation |
|---|---|---|
| Cloudflare Workers, Hono, KV, Durable Objects (SQLite per session) | Lyric on .NET 10, `Lyric.Web`, one SQLite DB, migrations inline in `src/db/repository.l` | Ledger tables in the shared SQLite DB (migration `0036_session_ledger`); a per-session change cursor stands in for the DO's single writer/fan-out point |
| Managed Agents API session, remote MCP URL + auth header | Each message runs `claude -p --resume` (or codex / opencode / gemini / antigravity) in a fresh container; the in-container `cloud-agents-shim` is a stdio MCP server that calls the host over REST with a per-session callback bearer token | The `ledger_*` tools live in the existing shim. No new MCP endpoint: `Lyric.Mcp` has no HTTP server transport (lyric-lang docs/64 Phase B is unbuilt) and the shim already works for every harness |
| Inject a user message into a running session (feedback push) | Not possible: a send while RUNNING is a 409; no stdin channel | Feedback is pulled by `ledger_check_feedback`, nudged by a `pendingFeedback` count on every ledger reply, and pushed at the next run's start (a one-line prompt prefix) |
| System-prompt instructions | Rules files rendered into the workspace (`docker/session-tools-guide.md` → `.claude/rules/session-tools.md`, GEMINI.md, opencode instructions); Codex gets an inline prompt prefix | Both rewritten with the spec's §10 agent instructions |
| zod, Vitest, ULID | `@generate(Json)` records + hand validation; `@test_module` suites with live SQLite; no ULID in the stdlib | Validation in the pure core; ids are UUIDv4, ordering comes from the per-session cursor (`createdSeq`) |
| ISO timestamps | Epoch-millisecond strings throughout the app | Epoch-millisecond strings |
| Alarm-driven GitHub sync / observer | Nothing runs periodically in-process; periodic work is an externally polled `POST /api/maintenance/*` endpoint | Phases 3–4 follow the maintenance-endpoint idiom (§9) |
| Inbound GitHub webhooks, GitHub App | Neither exists; OAuth App with `repo read:user` scope | Phase 3 polls with the owner's vaulted token |
| WebSocket / SSE live fanout | Runs stream over SSE-on-POST; everything else polls | Cursor polling (`GET …/ledger?after=<cursor>`), 3 s while a run streams, 10 s idle |
| `LedgerIndex` DO for a cross-session inbox | Single DB | One owner-scoped join query (`GET /api/ledger/inbox`) |

Two security findings from recon were filed separately rather than folded in:
`GET /api/sessions/{id}/events` and `/messages` are not owner-scoped, and
callback tokens are stored in plaintext (the ledger reuses that token rather
than minting a second one; hashing it at rest is the separate fix).

## 3. Domain model

Pure core, no storage/HTTP/Docker dependencies (`src/ledger/model.l`,
`state_machine.l`, `policy.l`, `summary.l`) — the unit meant to port to
Testamur (§8).

- **Entry kinds**: `decision`, `deviation`, `shortcut`, `blocker`,
  `question`, `note`.
- **Severity**: `info` (timeline only), `review` (attention queue, agent has
  proceeded), `blocking` (top of the queue; the related item cannot proceed).
- **Review state**: `pending`, `approved`, `rejected`, `commented`,
  `not_required` (info entries), plus `resolved` — an addition to the spec:
  the blocker entry a transition into `blocked` / `needs_human` creates is
  resolved (leaves the attention queue) when the item leaves that state.
- **Source**: `declared` (the agent), `observed` (reserved for Phase 4),
  `system` (the ledger, e.g. an auto-unblock note).
- **Work item refs**: `gh:owner/repo#N` or `local:<slug>`. The agent may
  write `#N` (this session's repo), `owner/repo#N`, a GitHub issue/PR URL, or
  a bare number; they are normalised.
- Vocabularies are validated strings, not unions: they round-trip through
  SQLite TEXT and JSON, and a union case name colliding with an imported one
  silently emits invalid IL in the current toolchain.

## 4. Work item state machine

| From | To | Actor |
|---|---|---|
| queued | in_progress, blocked, skipped, needs_human | agent, human |
| in_progress | pr_open, done, blocked, needs_human, skipped | agent |
| pr_open | done, in_progress | agent, github-sync |
| blocked | queued, in_progress, skipped | agent, human, github-sync |
| needs_human | queued, in_progress, skipped | human |
| skipped | queued | human |
| done | in_progress | human (reopen) |

- `blocked` requires a reason and `blockedBy` and/or `prerequisiteProposal`;
  `needs_human` requires a reason. Both write a `blocking` blocker entry and
  notify the owner through the existing notification feed. Entering either
  state starts a fresh blocker from what the actor gives now; leaving it
  clears the reason, `blockedBy` and `prerequisiteProposal`, and resolves the
  blocker entry whoever raised it.
- A same-state "transition" is a field update (recommendation, PR URL,
  blockers), always allowed.
- **Auto-unblock**: when an item reaches `done`, every `blocked` item whose
  `blockedBy` refs are all in-batch items now `done` moves to `queued`, with
  an info note. Items blocked on refs outside the batch wait for Phase 3.
- Invalid moves return the allowed targets, verbatim to the agent.
- Transitions are optimistic: the item UPDATE is guarded on the version the
  plan was computed against, and every dependent write is conditioned on it
  in the same transaction; the service re-plans up to three times.
- An agent referencing an unregistered item registers it (`queued`).

## 5. Severity policy

The agent may propose a severity; policy raises it, never lowers it. Default
rules: `shortcut`, `deviation` and `question` → review; `reversible: false` →
review; tags `tests`, `deps`, `schema`, `security`, `api-change`, `migration`
→ review; `blocker` → blocking; files matching `**/*.lock`,
`**/migrations/**`, `.github/workflows/**` → review; observed-and-undeclared
→ review. (`question` → review is an addition: a question exists to get input
and belongs in the queue.)

A repository adds rules in `.agent-ledger.json` (spec §8 format, `match` keys
`kind`, `reversible`, `tagsAny`, `filesGlob`, `source`, `undeclared`).
Repo rules are **appended** to the defaults, so they can only add floors.
The file is read from the repository's **default branch** via the GitHub
contents API with the owner's vaulted token — never from the workspace or
working branch, which the agent can edit. It is fetched once per session on
the first recorded entry and cached (`absent`, `loaded`, `invalid` with the
parse error, or `unavailable`); an invalid file is shown in the UI and the
defaults apply. `unavailable` (a GitHub failure) is retried on the next
entry rather than kept for the session. Globs are matched by dynamic
programming, so a hostile pattern costs O(pattern x path). Unknown `match` keys are rejected so a typo cannot silently
widen a rule.

## 6. Interfaces

### Agent tools (in-container shim, `shim/src/ledger_tools.l`)

| Tool | When the agent calls it |
|---|---|
| `ledger_get_state` | Start of every run and after context compaction |
| `ledger_register_items` | Once the batch is known (or one `local:` item for a single task) |
| `ledger_set_item_status` | Every item state change; `blocked` + recommendation, then move on |
| `ledger_record_decision` | A choice a reviewer might have made differently |
| `ledger_record_deviation` | Departing from the issue/plan (`deviation`) or doing less than ideal (`shortcut`) |
| `ledger_ask` | Input would help but work continues with `proceedingWith` |
| `ledger_note` | Follow-ups and discoveries for the human (replaces `add_followup_task`) |
| `ledger_check_feedback` | Before each new item, before a PR, and when a reply says feedback is waiting |

Each tool forwards its raw MCP `arguments` to
`POST /api/sessions/{id}/callbacks/ledger/{op}` (callback-token auth).
`CloudAgents.Ledger.ToolArgs` decodes them tolerantly (booleans as
`true`/`"true"`, a lone string for a list, bare refs for items) so the
argument contract lives in one place. The host answers every authenticated
call with 200 and `{ok, error, reply}`: the shim's `HttpWebRequest` drops
non-2xx bodies, and the agent needs the host's message to correct itself.
Every reply carries `pendingFeedback`.

### Human API (owner-scoped)

```
GET  /api/sessions/{id}/ledger?after=<cursor>       snapshot, or the delta since cursor ("unchanged" when nothing moved)
GET  /api/sessions/{id}/ledger/entries/{eid}        entry + its feedback + item transitions + transcript excerpt
POST /api/sessions/{id}/ledger/entries/{eid}/review {kind: approve|reject|comment, body}
POST /api/sessions/{id}/ledger/feedback             {item?, kind: directive|comment, body}
POST /api/sessions/{id}/ledger/items                {items: [{id, title, url}]}
POST /api/sessions/{id}/ledger/item-state           {item, to, reason}   (item ids carry / # :, so they travel in the body)
GET  /api/ledger/inbox                              pending review entries across the user's sessions
```

`reject`, `comment` and `directive` require a body. A session the caller
doesn't own is a 404.

### Feedback delivery

1. **Pull**: `ledger_check_feedback` claims undelivered rows with a fresh
   batch id and returns exactly those (`deliveredVia = mcp_poll`), so
   feedback created mid-claim is never marked delivered unseen.
2. **Nudge**: every ledger reply includes the pending count and a hint.
3. **Push at next run**: when feedback is waiting and the session's profile
   exposes `ledger_check_feedback`, the next run's prompt (interactive and
   scheduled-job) is prefixed with a one-line instruction to call it. The
   feedback itself is not pasted, so delivery tracking stays exact.

A cloud-agents session is long-lived (every message resumes it), so the
spec's "deliver to the next session on the same repo" case collapses into
(3). A rejection never reverts anything automatically; the agent acts on it,
and a revising entry names the original in `supersedes`.

### Transcript excerpt

Each declared entry stores the session's latest captured `session_events`
seq at the moment it was recorded (`transcriptSeq`). Entry detail renders the
40 captured events up to it through the existing stream-json renderer. The
capture poll loop lags the agent by up to a tick, so the anchor is
approximate to within a second or so.

### Attention

The session-list projection gains `ledgerAttention` (pending review count);
a session with pending ledger reviews has attention `pending`, alongside
pending permission / question / secret callbacks.

## 7. Consolidation

The ledger is the single agent-reporting channel for a session's work:

| Retired | Replaced by |
|---|---|
| `add_todo` / `update_todo` / `list_todos` (agent's plan) | work items + `ledger_set_item_status` / `ledger_get_state` |
| `add_followup_task` (note for the human) | `ledger_note` |
| Human todos read by the agent via `list_todos` | ledger directives (`POST …/ledger/feedback`), delivered via `ledger_check_feedback` |

Unchanged: human todos and bookmarks (a human feature), `ask_user`
(blocking — use when the agent cannot continue), `report_progress` (live
status line), `notify` (the ledger fires it itself for blockers), repo tasks
`add_task` / `list_tasks` / `complete_task` (a cross-session backlog for
future sessions), and the markdown-checkbox plan fallback for sessions
without the ledger tools.

Tools are enabled by default (an `all`-mode profile gets them). Migration
0036 grants all eight to any `selected`-mode profile that granted a retired
tool, then removes the retired grants; other `selected` profiles are left as
their operator chose.

## 8. Porting to Testamur

`CloudAgents.Ledger.{Model,StateMachine,Policy,Summary}` depend only on the
Lyric stdlib and the pure `CloudAgents.Text`. A port needs, per Testamur's
ADRs: a spec + ADR first; Postgres DDL with `tenant_id` leading every key and
`FORCE ROW LEVEL SECURITY` (ADR-0019); `@p0` placeholders; and the store
rewritten against `Lyric.Db`. The SQLite store here is not portable as is.

## 9. Follow-ups (not built)

- **Phase 3 — GitHub reconciliation**: `agent:*` labels, one structured
  blocker comment per item (hidden marker, edited in place), inbound polling
  via a `POST /api/maintenance/ledger-sync` endpoint in the existing
  maintenance idiom, auto-unblock on refs outside the batch. Uses the owner's
  vaulted OAuth token (`repo` scope); a GitHub App is the longer-term option.
- **Phase 4 — observer**: extract undeclared decisions/shortcuts from
  `session_events` with Claude Haiku, reconcile against declared entries
  (deterministic, in the core), badge `undeclared`. Needs a hand-written
  Messages API client (none exists in lyric-lang) and budget controls. The
  schema already carries `source`, `undeclared` and `matchedEntryId`.
- **Phase 5 — external harnesses**: the shim binary works for any local
  MCP-capable harness given a session token; a "create external session"
  action and hook ingestion are open.

## 10. Open questions

Recorded rather than guessed (spec §20):

- Should a rejected shortcut ever trigger an automatic revert? (Today: never.)
- Should `blocking` optionally pause work on every item, not just the
  affected one?
- Retention for ledger rows after a session is archived (today: kept, like
  every other session table).
- Should the observer backfill completed sessions?
- Should the repo policy be re-read per run rather than once per session?
