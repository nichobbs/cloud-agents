# Phase 6 — In-container MCP callback server

Status: complete — §6 steps 1-4, the §8 follow-ups (#540, #541), and
§7's three v2 tools are all shipped. Step 1 (host-side callback
endpoints, DB, tests) landed in PR #525; step 2 (token minting, env
injection, mcp.json/entrypoint rendering) landed in the same PR; step 3
(the shim itself, `shim/` — `CloudAgentsShim` on
`Lyric.Mcp`/`Lyric.JsonRpc` 0.4.34, the v1 tools, wired into
`scripts/build-docker.sh`/`docker/Dockerfile` and CI) landed in PR #526,
genuinely confirmed end-to-end over real MCP stdio. Step 4 is this
change: `CLOUD_AGENTS_MCP_CALLBACKS` now defaults on (opt out with
`=0`), `settings.json.template` shrinks to the read-only base set, and
the §8 follow-ups shipped alongside (wall-clock long-poll deadline,
seeded-session e2e legs). **§7's v2 tools (`request_secret`,
`add_followup_task`, `report_artifact`) also ship in this change** —
host endpoints (`src/handlers/callbacks.l`), migration `0011`
(`secret_requests` + `artifacts` tables), the `secret_request`/
`artifact_reported` SSE events, and the shim side
(`shim/src/v2_transport.l`/`v2_client.l`/`v2_tools.l`, registered in
`shim/src/main.l`), each with handler/state-machine/tool-level tests
(`tests/callbacks_v2_tests.l`, `shim/tests/v2_client_tests.l`,
`shim/tests/v2_tools_tests.l`). `request_secret`'s write-once value
delivery, the fail-fast missing-credential check, the 0600-permission
secret file (best-effort `chmod`; `Std.File` has no permission-setting
primitive — see `CloudAgents.Shim.V2Client`'s module doc), the 8 MiB
artifact cap (client- and server-side), and `fileName` basename
sanitization are all covered by tests.

Upstream prerequisite: `nichobbs/lyric-lang` `docs/62-jsonrpc-mcp.md` (the
`Lyric.JsonRpc` / `Lyric.Mcp` libraries this phase consumes via the
`[nuget]` pin) — published 2026-07-19 at version 0.4.34.

## 1. Problem

Agent containers are fire-and-forget today: one `claude -p … --resume`
invocation per turn (`docker/entrypoint.sh`), stdout streamed to the
browser over SSE (`CloudAgents.Streaming`), tool permissions decided
*before* the run starts via a static allowlist
(`docker/settings.json.template`) or `--yolo`
(`docker/entrypoint-gemini.sh`). Nothing running inside a container can
pause and ask the human anything. That forces the permission posture to
be either too loose (yolo) or too tight (blocked run dies).

## 2. Architecture

A small MCP server, `cloud-agents-shim`, written in Lyric against
`Lyric.Mcp`, ships inside every runner image and is registered in the
agent CLI's MCP config alongside the existing GitHub server
(`docker/mcp.json.template`). It speaks MCP over stdio to the agent CLI
and plain HTTPS to the host API:

```
agent CLI ──stdio/MCP──▶ cloud-agents-shim ──HTTP──▶ host API ──SSE──▶ browser
        ◀──tool result──               ◀──decision──          ◀──POST──
```

Container-side environment (injected by `docker_manager.l` at container
creation, rendered into `mcp.json` by `entrypoint.sh`):

- `CLOUD_AGENTS_API_URL` — base URL of the host API as reachable from
  the container network (the network policy must allow it and nothing
  else new).
- `CLOUD_AGENTS_CALLBACK_TOKEN` — per-session bearer token, minted at
  container creation, scoped to callback endpoints for that session
  only, expiring with the session. Never the user's OAuth token.

## 3. Permission prompts — the headline tool

Claude Code supports adjudicating non-interactive permission prompts
through an MCP tool: `claude -p --permission-prompt-tool
mcp__cloud-agents__request_permission`. The tool receives the pending
tool name + input and must return the documented JSON payload
(`{"behavior": "allow", "updatedInput": …}` or
`{"behavior": "deny", "message": …}`) as its text content.

`request_permission` implementation in the shim:

1. `POST {api}/api/sessions/{sid}/callbacks/permission` with
   `{toolName, input}` → host creates a `permission_requests` row
   (status `pending`), emits an SSE event on the session stream, and
   returns a request id.
2. Shim long-polls `GET …/callbacks/permission/{rid}` (25 s poll,
   overall timeout configurable, default 10 min).
3. Human answers in the UI → `POST …/callbacks/permission/{rid}/answer`
   (allow / deny / allow-always + optional note; auth: normal user
   auth, same session ownership checks as other handlers).
4. Shim returns the decision payload; on timeout it returns deny with
   an explanatory message (fail-closed).

`allow-always` persists a rule row (session-scoped in v1; profile-
scoped later) the host consults to auto-answer subsequent identical
requests without prompting.

With this in place, `settings.json.template`'s allowlist shrinks to the
genuinely-safe base set and everything else routes through the prompt.
Runner support matrix: claude — full support via
`--permission-prompt-tool`; gemini/codex/opencode — no equivalent flag
today, they keep their current posture (documented per-runner; the
shim's other tools still work for them where those CLIs support MCP).

## 4. Additional tools (same shim, same plumbing)

v1 (lands with the permission flow — same endpoints pattern, one PR
each at most):

- `ask_user(question, options?)` — free-text/multiple-choice question
  to the human; same pending/answer/SSE/long-poll machinery as
  permission requests, different table + event type. Gives every
  runner (not just claude) a mid-run escalation path the agent can
  invoke deliberately.
- `report_progress(summary, percentComplete?)` — fire-and-forget
  status line persisted on the session and pushed over SSE; the UI can
  show live "what is it doing" without parsing raw stdout.

v2 tools are specced in §7.

## 5. Host-side changes (this repo)

- New package `CloudAgents.Callbacks` (`src/handlers/callbacks.l`):
  the endpoints above, bearer-token auth middleware for
  container-originated calls, ownership checks for user-originated
  answers.
- DB: `permission_requests` and `user_questions` tables +
  `permission_rules` for allow-always (sqlite migrations in
  `src/db/`).
- `CloudAgents.Streaming`: two new SSE event types
  (`permission_request`, `user_question`) and `progress_update`.
- `docker_manager.l`: mint the callback token, pass the two env vars,
  extend the network policy exactly enough for the API callback
  origin.
- `docker/mcp.json.template` + `entrypoint.sh`: register the shim;
  `entrypoint.sh` adds `--permission-prompt-tool` for the claude
  runner.
- `docker/Dockerfile*`: ship the shim binary + .NET runtime layer it
  needs.
- Shim source: `shim/` in this repo (own `lyric.toml`, `[nuget]` pins
  `Lyric.Mcp`), built in CI alongside the main project and copied into
  runner images by `scripts/build-docker.sh`.

Every flow is testable Docker-free: handler tests hit the endpoints
in-process (as `tests/main_tests.l` does today), the shim's
request/poll/answer state machine is tested against an in-memory
transport fake (`shim/tests/fakes.l`), the real HTTP boundary is driven by
`scripts/e2e-http.sh`'s shim leg (real MCP stdio against the live server),
and the timeout/fail-closed path has an explicit test.

## 6. Sequencing

1. Host-side callback endpoints + DB + SSE events + tests (no upstream
   dependency — can land first).
2. Container plumbing: token minting, env injection, mcp.json/
   entrypoint rendering behind a feature flag until the shim exists.
3. Shim in Lyric on `Lyric.Mcp` (blocked on the upstream release
   carrying `Lyric.JsonRpc`/`Lyric.Mcp`; the `[nuget]` pin bump is the
   switch).
4. Flip claude runner to `--permission-prompt-tool`, tighten
   `settings.json.template`.

## 7. v2 tools — agreed designs

All three ride the existing authenticated shim↔host HTTPS channel and
the existing SSE/approval machinery. No new Docker-daemon capability is
required: the shim already runs inside the container, so it can write
files in (secrets) and read files out (artifacts) itself.

### 7.1 `request_secret(name, reason)`

Threat model: the primary risk is prompt-injected exfiltration — an
agent tricked into requesting a credential and echoing it onward. The
design therefore never lets the secret value enter the agent-visible
transcript, and never grants without a human in the loop:

1. Shim `POST …/callbacks/secret` `{name, reason}` → pending row in a
   new `secret_requests` table + `secret_request` SSE event. Reuses the
   permission long-poll shape.
2. Human approves or denies in the UI (normal user auth + ownership).
   **No allow-always for secrets — every request prompts.** The
   credential must exist in the session owner's credential store; the
   approval flow shows only the credential *name*, never the value.
3. On approval the host returns the decrypted value **once** in the
   long-poll response body (the channel is already bearer-authenticated
   HTTPS carrying the callback token). The host writes an audit row
   (session, name, reason, decision, timestamp) — the value is never
   logged or persisted outside the existing encrypted store.
4. The shim writes the value to a container-local file
   (`/run/cloud-agents-secrets/<name>`, 0600, tmpfs when available) and
   the MCP tool result returns **only the file path**. The value itself
   never appears in tool-result text, so it cannot land in stored
   transcripts or streamed output.
5. Timeout/deny → tool result is a denial message; fail closed.

### 7.2 `add_followup_task(description)`

Shim `POST …/callbacks/todo` `{description}` → the same todo storage
`CloudAgents.Interactions.addTodoHandler` uses (anchored to the
session's latest message, or unanchored if the schema allows), emits
the existing todo SSE/refresh signal, returns the created id. Available
to every runner with MCP support, giving agents a deliberate "leave a
note for the human" primitive.

### 7.3 `report_artifact(path, mimeType, description?)`

Container files die with the container, so the shim pushes content out
at report time: it reads `path` from inside the container (size cap
8 MiB v1 — reject larger with a clear message), base64s it, and
`POST …/callbacks/artifact` `{fileName, mimeType, description,
contentBase64}`. Host stores the bytes under a per-session artifacts
directory (outside the DB), writes an `artifacts` metadata row, emits
an `artifact_reported` SSE event, and serves
`GET /api/sessions/{id}/artifacts` (list, user auth) +
`GET /api/sessions/{id}/artifacts/{aid}` (download, user auth,
Content-Disposition from the stored name). Path traversal in
`fileName` is neutralized server-side (basename only).

## 8. Stage 4 and follow-ups

**Shipped.** Stage 4 (flip the default):

- `callbacksFeatureEnabled()` is default-on: enabled unless
  `CLOUD_AGENTS_MCP_CALLBACKS=0` (`src/network_policy.l`).
  `docker/entrypoint.sh` mirrors the same on-unless-"0" default in shell
  (it reads the env var directly rather than calling into Lyric). The
  entrypoint's existing guards (template present, env vars minted) keep
  runs working when the host side is unavailable — a run without a
  minted callback token (mint is best-effort; see
  `docker_manager.l`) behaves exactly as before the feature existed:
  neither the callback MCP-server entry nor `--permission-prompt-tool`
  is added unless THIS run's container actually has a non-empty
  `CLOUD_AGENTS_CALLBACK_TOKEN`, so a doomed-to-panic shim (its
  `requireEnv` panics on a missing required var) is never registered as
  the thing standing between the agent and every tool call.
- `docker/settings.json.template` shrinks to the genuinely-safe base
  set (`Read`, `Glob`, `Grep` — file reads and read-only inspection; no
  blanket `Bash(git:*)`), with everything else routed through
  `request_permission`. The claude runner keeps `--permission-prompt-tool`
  (already wired, now active by default). The posture rationale lives as
  a comment in `docker/entrypoint.sh` next to where the template is
  copied, not inside the template itself — CI validates
  `settings.json.template` with `python3 -m json.tool`, which rejects
  JSONC-style comments.
- Non-claude runners keep their documented posture (no equivalent
  flag), unchanged by the flip.

Follow-ups (both shipped):

- #540: `shim/src/callbacks_client.l`'s long-poll deadline is wall-clock
  now — a `Clock` interface (mirroring lyric-cache's `Clock`, including
  keeping every `impl Clock for ...` in the same package per that
  library's own self-hosted-MSIL-backend caveat) with `SystemClock`
  (real `Std.Time.nowEpochMillis()`) in production and `ManualClock` in
  tests, instead of iteration-count × nominal interval. The public
  `requestPermission`/`askUser` signatures are unchanged (thin
  `SystemClock` wrappers), so `shim/src/tools.l`/`main.l` needed no
  changes; `requestPermissionWithClock`/`askUserWithClock` are the new
  testable entry points. `shim/tests/callbacks_client_tests.l` proves
  the wall-clock behavior with a transport that jumps a shared
  `ManualClock` straight past the deadline mid-poll, despite a
  pollIntervalMs implying many more iterations remained.
- #541: `scripts/e2e-http.sh` gained a seeded-session leg — a plain
  `sqlite3` CLI `INSERT` (guarded by a `command -v sqlite3` check) adds
  a session + plaintext `callback_token` row to the throwaway DB after
  migrations have run, then drives the real shim binary once with a
  wrong bearer (401-driven deny, `SELECT COUNT(*) FROM
  permission_requests` stays 0) and once with the right bearer and
  `CLOUD_AGENTS_CALLBACK_TIMEOUT_MS=1000` (a pending row IS created,
  count becomes 1, then the shim's own #540 wall-clock deadline fires a
  timeout deny in ~1s instead of the old code's ~25s) — covering both
  halves of `authorizeCallbackToken` the unknown-session 404 leg cannot
  reach.
