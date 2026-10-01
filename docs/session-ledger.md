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
| Cloudflare Workers, Hono, KV, Durable Objects (SQLite per session) | Lyric on .NET 10, `Lyric.Web`, one SQLite DB, migrations inline in `src/db/repository.l` | Ledger tables in the shared SQLite DB (migration `0037_session_ledger`); a per-session change cursor stands in for the DO's single writer/fan-out point |
| Managed Agents API session, remote MCP URL + auth header | Each message runs `claude -p --resume` (or codex / opencode / gemini / antigravity) in a fresh container; the in-container `cloud-agents-shim` is a stdio MCP server that calls the host over REST with a per-session callback bearer token | The `ledger_*` tools live in the existing shim. No new MCP endpoint: `Lyric.Mcp` has no HTTP server transport (lyric-lang docs/64 Phase B is unbuilt) and the shim already works for every harness |
| Inject a user message into a running session (feedback push) | Not possible: a send while RUNNING is a 409; no stdin channel | Feedback is pulled by `ledger_check_feedback`, nudged by a `pendingFeedback` count on every ledger reply, and pushed at the next run's start (a one-line prompt prefix) |
| System-prompt instructions | Rules files rendered into the workspace (`docker/session-tools-guide.md` → `.claude/rules/session-tools.md`, GEMINI.md, opencode instructions); Codex gets an inline prompt prefix | Both rewritten with the spec's §10 agent instructions |
| zod, Vitest, ULID | `@generate(Json)` records + hand validation; `@test_module` suites with live SQLite; no ULID in the stdlib | Validation in the pure core; ids are UUIDv4, ordering comes from the per-session cursor (`createdSeq`) |
| ISO timestamps | Epoch-millisecond strings throughout the app | Epoch-millisecond strings |
| Alarm-driven GitHub sync / observer | Nothing runs periodically in-process; periodic work is an externally polled `POST /api/maintenance/*` endpoint | Phases 3–4 follow the maintenance-endpoint idiom (§9, §10) |
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
  a bare number; they are normalised, with owner/repo lowercased and
  leading zeros dropped so one issue is always one ref. Link fields
  (`prUrl`, an item's `url`) must be absolute http(s) URLs, and the PWA
  only renders http(s) hrefs.
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
entry rather than kept for the session. GitHub answers 404 both for a
missing file and for a repository the token cannot see, so a 404 counts as
`absent` only once the repository itself is confirmed readable; otherwise it
is `unavailable`.

Glob syntax: `*` matches within one path segment, `?` one non-`/`
character, `**` any run including `/`, and `**/` also matches zero
directories, but only at a segment start (`**/test.py` matches `test.py`
and `a/test.py`, never `src/latest.py`).

Validation rejects, with a message naming the rule and the limit:
- unknown `match` keys, so a typo cannot silently widen a rule;
- `tagsAny` values that are not valid entry tags (1-32 of `a-z 0-9 -`), so a
  typo cannot silently make a rule unmatchable;
- more than 10 tags or 20 globs in a rule, 50 globs across the file, or a
  glob over 256 characters.

Globs are matched by dynamic programming (O(pattern x path), never
exponential). Matching one entry's files against every glob is also
budgeted; an entry over the budget has its file globs treated as matching,
which can only put it in front of a reviewer.

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

A poll reads the cursor first and returns `unchanged` without loading any
rows when nothing moved. Lists are capped (1000 items, 5000 entries, 2000
feedback rows); a delta that reaches a cap is replaced by a full snapshot.
Past the entry or feedback cap a full snapshot carries the **newest** rows
and `truncated: "true"`. A session's batch is capped at 1000 work items, so
the item list is never truncated. Summary counts are computed in SQL over
every row, so they stay right however large a session grows.

### Feedback delivery

1. **Pull**: `ledger_check_feedback` claims undelivered rows with a fresh
   batch id and returns exactly those (`deliveredVia = mcp_poll`), so
   feedback created mid-claim is never marked delivered unseen. Everything
   that can fail runs before the claim, and a failed read-back releases the
   batch, so an error reply never loses feedback. The read-back joins the
   answered entry's summary, so nothing else is read after the claim.
2. **Nudge**: every ledger reply includes the pending count and a hint.
3. **Push at next run**: when feedback is waiting, MCP callbacks are enabled
   (`CLOUD_AGENTS_MCP_CALLBACKS` is not `0`) and the session's profile
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
0037 grants all eight to any `selected`-mode profile that granted a retired
tool, then removes the retired grants; other `selected` profiles are left as
their operator chose.

## 8. Porting to Testamur

`CloudAgents.Ledger.{Model,StateMachine,Policy,Summary}` depend only on the
Lyric stdlib and the pure `CloudAgents.Text`. A port needs, per Testamur's
ADRs: a spec + ADR first; Postgres DDL with `tenant_id` leading every key and
`FORCE ROW LEVEL SECURITY` (ADR-0019); `@p0` placeholders; and the store
rewritten against `Lyric.Db`. The SQLite store here is not portable as is.

## 9. GitHub reconciliation (Phase 3)

Items whose id is a GitHub issue (`gh:owner/repo#N`) are mirrored onto that
issue, and changes made on GitHub flow back. Local items are never synced.

**Outbound.** Each synced issue carries exactly one managed label for the
item's state; other labels are never touched. A skipped item's issue carries
none.

| State | Label |
|---|---|
| queued | `agent:queued` |
| in_progress | `agent:in-progress` |
| pr_open | `agent:pr-open` |
| blocked | `agent:blocked` |
| needs_human | `agent:needs-human` |
| done | `agent:done` |

Managed labels are created in the repo on first use. A blocked or
needs_human item gets one structured comment (reason, blockers as `#N` or
`owner/repo#N`, proposed prerequisite work, the agent's recommendation),
identified by a hidden `<!-- agent-ledger:session=…;item=… -->` marker and
edited in place as the item changes. Once the item is unstuck the comment is
rewritten as resolved rather than deleted. A comment deleted on GitHub is
found again by its marker or posted anew.

**Inbound.** Each pass reads the issue before writing:

- a `pr_open` item whose pull request is merged moves to `done` (actor
  `github-sync`), and the usual auto-unblock runs;
- a person removing the `agent:blocked` / `agent:needs-human` label the
  ledger applied, or adding `agent:queued`, requeues the item (actor
  `human`). Only a label the ledger itself put there counts as removed, and
  the ledger's own stale `agent:queued` is not read as a request;
- a blocked item whose blockers are all resolved (an in-batch item that is
  done, or a GitHub issue that is closed) is requeued (actor `github-sync`).
  This is how blockers outside the batch unblock.

Every inbound move writes a system note saying why.

**When.** There is no in-process timer. Two endpoints:

```
POST /api/maintenance/ledger-sync        operator only; polled by an external scheduler
POST /api/sessions/{id}/ledger/sync      owner; the panel's "Sync with GitHub" button
```

Both return `{sessions, items, transitions, calls, errors}`. Sync state lives
in `ledger_github_sync` (migration 0038): the label last applied, the comment
id and body hash, the last error and when the item last synced. An item is
due when it changed since its last sync, its last sync failed, or it is in a
state GitHub can move (blocked, needs_human, pr_open). The maintenance run
takes at most 20 sessions, 60 GitHub calls per session and 300 per run;
whatever is left waits for the next run. Sessions go least recently
attempted first (`ledger_github_sync_runs`, which also records a session
that failed before reaching GitHub), and within a session items go least
recently attempted first (success or not), so neither a failing session, a
failing item nor always-due stuck items starve the rest. A pass holds a
per-session lease (`lease_until`, 30 minutes, released at the end), so the
maintenance run and the sync button never work one session at once; the
button answers 409 while a pass runs.

**Ownership.** A label and a comment live on the issue, so exactly one
session manages an issue: the most recent non-archived session to register
it. An older session's item stays as it was and is not synced, so two
sessions never fight over labels or read each other's changes as a
person's. Archiving a session hands its issues back to the previous one.

**Responses.** Calls are 2xx-only with redirects off, so a transferred or
renamed repo's 3xx is an error, not a body. An issue body without a
`state` of open/closed and a `labels` array is rejected rather than read as
an issue with no labels. Unchanged labels and comment bodies
make no writes, so repeated passes are idempotent.

**Credentials.** Calls run as the session owner, with the GitHub App user
token from their connected account (`ensureFreshGitHubToken`). The App needs
Issues read/write and Pull requests read. A failure is recorded against the
item and retried next pass; an owner without a usable token gets an error
telling them to reconnect GitHub.

## 10. Observer (Phase 4)

The observer finds what the agent did but didn't declare: decisions a
reviewer might have made differently, deviations, shortcuts and blockers. It
is another agent session, not a direct model call: the owner picks its
harness and model on the profile, and it runs on the user's existing
credentials. The agent proposes; a deterministic core decides.

**Settings (per profile).** `GET`/`POST /api/profiles/{id}/observer`,
edited in the profile editor. A session is observed iff its profile's
observer is enabled.

| Setting | Values |
|---|---|
| `enabled` | `true` / `false` |
| `harness`, `model` | any runner harness; model `""` = the harness default |
| `repoAccess` | `none` (transcript only), `diff` (plus the observed workspace's `git diff HEAD`), `workspace` (plus a read-only mount of the observed workspace at `/workspace/observed`) |
| `midRunMinutes` | `0` (end of run only), `15`, `30`, `60` |
| `maxPassesPerDay` | 1 to 500 passes per observed session per UTC day |

**The observer session.** One long-lived hidden session per observed session
(`sessions.observes_session_id`), created on first use. It resumes on each
pass and sees only events after its cursor, so it keeps context across runs.
Changing the harness, model or repo access starts a fresh observer; the
cursor lives in `ledger_observer`, not in the observer, so nothing is
reported twice. It is hidden from session lists, never observed itself, and
deleted with the session it observes.

It runs on the observed session's profile for credentials and network
policy, but its container is narrowed whatever the profile grants:

- only `observer_get_window` and `observer_report`, no other shim tools;
- no skills, subagents or MCP servers;
- only its harness's model credentials, an allowlist
  (`ObserverPolicy.observerCredentialNames`: e.g. `ANTHROPIC_API_KEY` and
  `CLAUDE_CODE_OAUTH_TOKEN` for Claude); every other credential the profile
  grants, repository and cloud tokens included, is withheld;
- no clone of its own (`CLOUD_AGENTS_OBSERVER=1`);
- at most a read-only view of the observed workspace.

For Claude, its permissions allow only `Read`, `Glob`, `Grep` and the two
observer tools, and there is no permission-prompt route, so any other tool
is refused rather than put to the owner. Other harnesses rely on the
container limits above: they can run commands inside the observer's own
container, but can't change the observed workspace or push anywhere.

Its callbacks use its own token on
`POST /api/sessions/{observerId}/callbacks/observer/{window|report}`; the
host maps the observer to the session it observes.

**Triggers.** No in-process timer, as elsewhere:

- a run's end (success, failure or cancel, interactive or scheduled) queues a
  pass;
- while a run goes on, its poll loop queues a mid-run pass once the interval
  has passed since the last pass (checked about once a minute);
- `POST /api/sessions/{id}/ledger/observe` queues one on demand (the panel's
  "Observe now");
- `POST /api/maintenance/observe` (operator only, polled by an external
  scheduler like `trigger-jobs`) runs up to 3 due passes per call.

A pass is skipped without starting a container when nothing new was captured,
or when the new events are only reads and searches (the cursor then moves past
them). Every pass counts towards the daily cap; a pass that fails or ends
without reporting records `lastError`, and its window is read again next time.

**A pass.** The observer calls `observer_get_window` and gets:

- the next window of up to 400 captured events or 60,000 characters, as
  `[seq N]` lines (the agent's words, each tool call with its salient inputs,
  truncated results);
- the work items and the last 80 entries (declared and already observed);
- the workspace diff, up to 30,000 characters, when `repoAccess` grants it;
- `final` (the run has ended) and `more` (another window follows).

It answers with one `observer_report`: a list of candidates, each with kind,
summary, detail, item, `seqStart`..`seqEnd` within the window, tags, files,
reversible, confidence (0..1) and evidence (a quote, kept to 30 words). A
report is validated whole: any bad candidate rejects it with a message naming
it, so the observer can fix and resend. On acceptance the cursor moves past
the window.

**Reconciliation** (`CloudAgents.Ledger.Reconcile`, pure):

- confidence below 0.5 is dropped;
- a candidate restating an earlier observation (same kind family and item,
  and near-identical wording or an overlapping range with similar wording) is
  a duplicate and not stored;
- a candidate covered by a declared entry (same kind family, a compatible
  item, the declared entry's transcript anchor within 30 events of the range,
  and related by wording or a shared file) is stored as matched: severity
  info, no review, `matchedEntryId` set;
- anything else is stored undeclared (`source: observed`,
  `undeclared: true`), which policy raises to at least review.

Kind families: `decision`; `deviation`/`shortcut`; `blocker`/`question`.
Notes are the agent's own asides and are not observable.

An undeclared shortcut with confidence 0.8 or more, or an undeclared action
marked not reversible, notifies the owner; the rest wait in the panel and
inbox.

Findings from a mid-run pass are `provisional`. If the agent declares the
same thing later in the run, the next pass matches the observation to it
(it stops needing review unless the owner already reviewed it). When the run
has ended, the next pass settles the rest as final.

Observed entries carry `observedFrom`..`transcriptSeq` (their event range),
`confidence` and `evidence`; the PWA badges them observed / undeclared /
provisional and shows the evidence in the entry detail.

**Tests.** `tests/fixtures/observer/` holds a transcript in Claude's
stream-json shape, written for the tests, with a skipped test, a scope change
and an abandoned approach left undeclared and one declared decision, plus a
recorded observer report. `tests/ledger_observer_tests.l` checks that the
three are flagged and the decision is matched, not duplicated.
`tests/observer_handlers_tests.l` runs whole passes through the real
callbacks with a fake runner playing the observer agent.

## 11. Follow-ups (not built)

- **Phase 5 — external harnesses**: the shim binary works for any local
  MCP-capable harness given a session token; a "create external session"
  action and hook ingestion are open.
- **Observer, live check**: passes are tested against a fake runner; a live
  pass with each harness against a real container is the remaining manual
  step.

## 12. Open questions

Recorded rather than guessed (spec §20):

- Should a rejected shortcut ever trigger an automatic revert? (Today: never.)
- Should `blocking` optionally pause work on every item, not just the
  affected one?
- Retention for ledger rows after a session is archived (today: kept, like
  every other session table).
- Should the observer backfill completed sessions?
- Should the repo policy be re-read per run rather than once per session?
