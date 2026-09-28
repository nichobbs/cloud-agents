# Spec: `GET /api/sessions/{id}/events` endpoint

Status: **Implemented.** The endpoint half of the WP4 acceptance
(Testamur §4.1 / ADR-0004; `docs/CAPABILITY_AUDIT.md` WP4), landing on top of
the durable store (`docs/session-events-store.md`). It exposes a session's
persisted capture chain over HTTP so the platform's fetch-client can pull it,
re-`verifyChain` it, and hand it to `GraphIngest.ingestObjects` (the transport
half of `testamur/docs/specs/graph-handoff.md`).

## 1. Purpose and scope

The store persists a session's hash-chained `CaptureEvent`s
(`session_events`, migration `0030`) and reads them back with
`sessionEventsAfterSeq`. This work package is the read-side HTTP surface:
a single authenticated GET that streams a session's events, oldest first,
from a caller-supplied `seq` cursor — the exact shape a resumable, incremental
platform fetch needs.

**In scope:** the route + handler + a stable JSON envelope over
`sessionEventsAfterSeq`; `after` cursor and validation; auth parity with the
rest of `/api/sessions/*`.

**Out of scope / deferred:** wiring the Docker runner to *write* these rows
(needs a Docker host + the real `claude` harness); the platform-side
fetch-client that *consumes* this endpoint (lands in testamur); server-side
paging beyond the `after` cursor (the cursor already gives incremental,
resumable reads — a `limit` can be added later if a session's event count
warrants it).

## 2. Route

```
GET /api/sessions/{id}/events?after=<seq>
```

- `{id}` — the session id (path param). Empty → `400 id is required`.
- `after` — optional cursor (query param). Events with `seq` **strictly
  greater** than `after` are returned. Omitted or empty → from the beginning
  (the store maps `""` to the `-1` sentinel, so event `0` is included). `after`
  must be all ASCII digits when present; anything else → `400 after must be a
  non-negative integer` (so a non-numeric cursor can never be silently
  reinterpreted as `0` by SQLite's `CAST`).
- **Auth:** the route lives under `/api/sessions/`, so the global auth
  middleware (`src/main.l`) enforces it exactly like every other session route —
  captured events are sensitive audit data and are never served unauthenticated.
- **Ownership:** authentication alone is not enough. The `session_events` table
  carries no `user_id`; ownership is reachable only through the `sessions` row,
  so the handler first resolves `{id}` with the owner-scoped
  `CloudAgents.SessionStore.getSession` (scoped by
  `CloudAgents.Auth.currentUserId()`). A session owned by another user answers
  `404 Session not found`, byte-identical to a session that doesn't exist, so
  the endpoint never confirms another tenant's session id. The check runs
  before the store read and applies to every cursor value.

### 2.1 Operator token / Testamur `CaptureFetch`

The platform's `CaptureFetch` client authenticates with the static operator
token (`CLOUD_AGENTS_API_TOKEN`). `CloudAgents.Auth.authorize` resolves that
token to `operatorUserId()` (`"default"`), so `CaptureFetch` reads exactly the
sessions the operator identity owns:

- **Static-token / single-operator deployments** (no GitHub OAuth): every
  session is created under `"default"`, so `CaptureFetch` sees every session,
  as before.
- **OAuth deployments**: sessions created by a signed-in GitHub user are owned
  by that user's id, not `"default"`, and the operator token gets `404` for
  them. The operator token is deliberately **not** a cross-tenant read-all
  credential here; before this check existed it was (as was any other
  authenticated caller), which leaked every tenant's transcript-derived capture
  chain. A platform that must audit other users' sessions needs a dedicated,
  explicitly-privileged read path (an operator-only route in the style of
  `POST /api/maintenance/drain-graph-ingest`, which checks
  `currentUserId() == operatorUserId()`), not a widening of this user-facing
  endpoint.

## 3. Response

`200` with `Content-Type: application/json`:

```json
{"events":[
  {"seq":"0","type":"system","payload":"<raw NDJSON line, JSON-escaped>",
   "prevHash":"","hash":"<hex>"},
  {"seq":"1","type":"assistant","payload":"...","prevHash":"<hex>","hash":"<hex>"}
]}
```

- One object per `CaptureEvent`, in ascending `seq` order.
- `seq` is rendered as a **string** of digits (matching the store's TEXT `seq`
  and the `messages` endpoint's string seq), so no JSON-number precision
  concerns.
- `payload` is the **verbatim** captured NDJSON line emitted as a JSON *string*
  (escaped), not as a raw nested value. This keeps the envelope valid JSON even
  for a `malformed` event whose payload is not valid JSON, and lets the raw line
  round-trip byte-for-byte so the fetch-client can reconstruct the exact
  `CaptureEvent` and `verifyChain` it. `type` is the verbatim event type
  (or `"malformed"`).
- An owned session with no captured events returns `{"events":[]}`. An
  unknown session, or one owned by another user, returns `404 Session not
  found` (see §2 "Ownership") — consistent with the messages endpoint.

## 4. Implementation

- `CloudAgents.Interactions.getSessionEvents(id, afterSeq)` — validates `id`
  and `afterSeq`, gates on `requireOwnedSession(id)` (404 for a missing or
  foreign session), calls `sessionEventsAfterSeq`, encodes via
  `sessionEventsToJson`, returns `Result[String, Web.ApiError]`.
- `sessionEventsToJson` / `captureEventToJson` — pure encoders reusing
  `CloudAgents.Streaming.jsonEscape`, mirroring `messageListToJson`.
- `RouteGetSessionEvents` (`src/main.l`) — the Handler adapter: `pparam(req,
  "id")`, `qparam(req, "after")`, `jsonStringResp`. Registered with
  `Web.addGet(router, "/api/sessions/{id}/events", …)` next to the messages
  route.

## 5. Test strategy

- **Offline encoder** (`tests/db_tests.l`, no DB): `sessionEventsToJson` over a
  hand-built `CaptureEvent` slice produces the documented envelope; the `events`
  key and every per-event key are present; a payload containing `"` and `\`
  (and a `malformed` event whose payload is not valid JSON) is escaped so the
  envelope parses; an empty slice yields `{"events":[]}`; `seq` is emitted as a
  string.
- **Handler validation** (offline): empty `id` → `badRequest`; a non-digit
  `after` → `badRequest`; empty and all-digit `after` are accepted.
- **Live round-trip** — deferred with the runner wiring: exercising the full
  route needs the running `Lyric.Web` server; the store's own live suite
  (`tests/session_events_tests.l`) already proves `sessionEventsAfterSeq`
  round-trips and honors the cursor, which is the data path this endpoint wraps.

## 6. Acceptance criteria

1. `GET /api/sessions/{id}/events` returns the session's events as the §3
   envelope, ascending `seq`, `payload` verbatim-and-escaped.
2. `after` honors the store cursor (strictly greater; empty = from start).
3. `id` empty → 400; `after` non-numeric → 400.
4. The route is auth-enforced like the other `/api/sessions/*` routes.
5. A session the caller doesn't own → 404, indistinguishable from a missing
   session (`tests/interactions_tests.l` "user B cannot read user A's messages
   or capture events" and "operator identity reads its own sessions' events but
   not an OAuth user's", live SQLite).
6. Offline encoder + handler-validation suites pass with no DB.
