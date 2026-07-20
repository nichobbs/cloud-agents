# Phase 6 — In-container MCP callback server

Status: §6 steps 1-3 shipped. Step 1 (host-side callback endpoints, DB,
tests) landed in PR #525. Step 2 (token minting, env injection, mcp.json/
entrypoint rendering behind `CLOUD_AGENTS_MCP_CALLBACKS`) landed in the same
PR. Step 3 (the shim itself, `shim/` — `CloudAgentsShim` on
`Lyric.Mcp`/`Lyric.JsonRpc` 0.4.34, three tools, `shim/tests/`, wired into
`scripts/build-docker.sh`/`docker/Dockerfile` and CI) is this change.
Genuinely confirmed end-to-end: a real spawned `cloud-agents-shim` process
completed a real MCP `initialize`/`tools/list` handshake over stdio, and a
real `request_permission`/`report_progress` `tools/call` round trip against
an unreachable host correctly failed closed (deny) and fired-and-forgot
respectively — not just unit-tested against the in-memory fake in
`shim/tests/fakes.l`. Step 4 (flip the `claude` runner's default to
`--permission-prompt-tool`, tighten `settings.json.template`) is
intentionally **not** part of this change — `CLOUD_AGENTS_MCP_CALLBACKS`
stays off by default; see §6.

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

v2 candidates (design notes only, not built now):

- `request_secret(name, reason)` — gated, audited handout from the
  credentials store; needs its own threat-model pass first.
- `add_followup_task(description)` — agent appends to the session's
  todo list (the `interactions.l` todos), closing the loop with the
  existing annotation feature.
- `report_artifact(path, mimeType)` — register a build artifact for
  download from the session page.

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
