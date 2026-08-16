# Spec: `session_events` store

Status: **Implemented.** Persistence half of the provenance-capture work
(Testamur §4.1 / ADR-0004; `docs/CAPABILITY_AUDIT.md` WP4). Follows the capture
core (`docs/capture-stream-json.md`) and the checkpoint bridge
(`docs/capture-checkpoint.md`).

## 1. Purpose and scope

`CloudAgents.Capture` parses a `claude -p --output-format stream-json` run into
hash-chained `CaptureEvent`s; `CloudAgents.CheckpointBridge` maps them to the
Testamur checkpoint format. Both are pure and in-memory. This work package makes
the captured chain **durable**: a `session_events` table plus append/read
Repository accessors, so a session's events survive the runner process and can
be re-read (and re-verified) later.

**In scope:** the `session_events` schema (migration `0030`), an idempotent
batch **append** of `CaptureEvent`s for a session, and a **read** of a session's
events with `seq` strictly greater than a cursor (oldest first) — the shape the
audit endpoint and the checkpoint bridge both consume.

**Out of scope / deferred:** the `GET /api/sessions/{id}/events?after=seq`
HTTP endpoint (the other half of the WP4 acceptance — it needs the running
`Lyric.Web` server to verify, so it lands as a follow-up on top of this store);
wiring the Docker runner to write these rows (needs a Docker host + the real
`claude` harness); and the graph handoff to the platform.

## 2. Schema (migration `0030_session_events`)

```
CREATE TABLE IF NOT EXISTS session_events (
  session_id  TEXT NOT NULL,
  seq         TEXT NOT NULL,   -- CaptureEvent.seq, digits; ordered via CAST AS INTEGER
  event_type  TEXT NOT NULL,   -- verbatim "type" or "malformed"
  payload     TEXT NOT NULL,   -- the raw NDJSON line, verbatim
  prev_hash   TEXT NOT NULL,   -- chain links (CloudAgents.Capture)
  hash        TEXT NOT NULL,
  created_at  TEXT NOT NULL,   -- store-time stamp (audit only; not part of the chain)
  PRIMARY KEY (session_id, seq)
)
```

`seq` is stored as TEXT and compared with `CAST(seq AS INTEGER)` — the same
convention as the `messages` table — so lexical storage still orders
numerically. The composite primary key `(session_id, seq)` both enforces
one row per event and serves the session-scoped, seq-ordered read (SQLite
builds the covering index), so no separate index is added. `created_at` is a
store-time value and is deliberately **not** part of the hash preimage (the
chain covers `prev_hash|seq|event_type|payload` only), so persisting never
invalidates a captured chain.

## 3. Accessors (`CloudAgents.Repository`)

- `appendSessionEvents(sessionId, events: slice[CaptureEvent]) -> Result[Int, DbError]`
  inserts a batch in **one transaction** (`executeTransaction`) — either the
  whole batch lands or none of it does, preserving chain contiguity. Inserts are
  `INSERT OR IGNORE` on `(session_id, seq)`, so re-appending an already-stored
  prefix (a resumed/retried capture) is an idempotent no-op rather than a
  primary-key error. Returns the number of statements executed.
- `sessionEventsAfterSeq(sessionId, afterSeq: String) -> Result[slice[CaptureEvent], DbError]`
  returns the session's events with `seq` strictly greater than `afterSeq`,
  oldest first — decoded back into `CaptureEvent`s so a reader can `verifyChain`
  them. `CaptureEvent` seq starts at **0**, so the empty cursor `""` maps to the
  sentinel `"-1"` (`seq > -1` includes event 0) — "from the beginning". `"0"` is
  a real `after=0` cursor and excludes the first event. `afterSeq` is compared as
  an integer, never interpolated as raw SQL (all values go through `sqlLiteral`).

Both are parameterized through `sqlLiteral` (single quotes doubled), so a payload
full of JSON quotes/apostrophes stores and round-trips verbatim.

## 4. Test strategy (two tiers, matching the repo)

- **Offline SQL-shape** (`tests/db_tests.l`, always run, no DB): the schema DDL
  names every column and the `(session_id, seq)` PK; the insert SQL is
  `INSERT OR IGNORE` and escapes a payload containing a `'`; the select SQL
  filters by `session_id`, compares `CAST(seq AS INTEGER)`, and orders ascending.
- **Live-SQLite round-trip** (`tests/session_events_tests.l`, gated on the native
  SQLite lib like the other live suites): parse a fixture stream-json chunk with
  `CloudAgents.Capture`, `appendSessionEvents`, then `sessionEventsAfterSeq("")`
  returns the same events (verbatim payloads, seq order) and they `verifyChain`;
  `sessionEventsAfterSeq` with a mid cursor returns only the tail; a second
  append of the same batch is an idempotent no-op (row count unchanged).

## 5. Acceptance criteria

1. Migration `0030` applies cleanly on a fresh DB (`initSchema`).
2. A captured batch appends and reads back verbatim, in seq order, and the
   read-back events `verifyChain` (live).
3. `sessionEventsAfterSeq` honors the cursor (strictly greater, oldest first).
4. Re-appending an already-stored prefix is an idempotent no-op (live).
5. Offline SQL-shape suite passes with no DB; payloads with quotes are safe.

## 6. Deferred (sequenced follow-ups)

`GET /api/sessions/{id}/events?after=seq` (endpoint half of WP4 acceptance);
runner wiring to write these rows; audit-row enrichment; graph handoff; NuGet
migration of the vendored checkpoint contract.
