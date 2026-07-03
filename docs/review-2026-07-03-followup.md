# Follow-up review — 2026-07-03 (post-PR #68)

Scope: frontend (`frontend/src/`), ops docs (`deploy/`, `docker/`, `Makefile`), and
the phase-design docs (`docs/phase*.md`, `docs/PROGRESS.md`) against actual
`src/` behavior. Complements `docs/review-2026-07-03.md`, which already covers
backend security (no auth enforcement, racy env-var session store, shared
credential volume) — those aren't repeated here. Items marked **(fixed here)**
were safe, mechanical, low-risk changes; everything else is a recommendation,
since larger behavioral changes still can't be compile-checked in this
environment (no local `lyric`/`dotnet`).

## Headline finding: "real-time streaming" doesn't stream

Two independent research passes (frontend, phase-docs) converged on the same
bug from different angles:

- `src/docker_manager.l:108-128` (`runSessionMessage`) blocks synchronously —
  `taskWaitMs` for up to 30 minutes — on the container fully exiting *before*
  fetching logs at all.
- `src/handlers/sessions.l:113-136` (`sendMessage`) only calls
  `CloudAgents.Streaming.formatLogsAsSseWithId` once, on the complete captured
  log string, after the container has already exited and been deleted.
- `frontend/src/hooks/useStreamMessage.ts` and `Terminal.tsx` present this as a
  live cursor, implying real-time output — but nothing is emitted until the
  whole run finishes. A user watching a session sees a blank "running…" panel
  for the entire run, then everything flushes at once.

This is the single biggest gap between what the product claims (`docs/phase1-core-loop.md`
explicitly says "stream the output back to the browser in real time") and what
it does. Fixing it for real means either polling `getContainerLogs` on an
interval while the container runs, or a genuinely streaming Docker logs
connection (`GET /containers/{id}/logs?follow=true`) piped through SSE as it
arrives — a real backend design change, not something to guess at without a
compiler. Flagging as the top recommendation for the next substantive piece of
work on this project.

## Other functional gaps

1. **GitHub MCP token is never wired to containers.** `docker/entrypoint.sh`
   and `docker/mcp.json.template` expect `$GITHUB_TOKEN`, but
   `src/docker_manager.l`'s `envs` list (lines 45-52) never sets it — grep
   across `src/` for `GITHUB_TOKEN` returns nothing. Every rendered
   `.claude/mcp.json` has an empty PAT, so the GitHub MCP server inside every
   container can never authenticate. `docs/PROGRESS.md` marks this "🟡" without
   flagging that it's a hard break, not partial progress.
2. **Credential encryption (Phase 3 §3) is entirely unimplemented**, not just
   pending. `docs/credentials.md` describes `PUT /api/users/me/credentials`,
   server-side encryption, and per-user decrypt-to-tempdir-then-wipe — none of
   it exists. `homeVolumeName(githubUserId, ...)` in `src/db/db_client.l` is
   dead code; `docker_manager.l` still hardcodes one shared
   `claude-home-default` volume for every session (already flagged as a
   security issue in the first review doc; this confirms the *documented
   design* for fixing it was never built, not just skipped informally).
   `ENCRYPTION_KEY` is referenced in `deploy/RUNBOOK.md` and gated by
   docker-compose's `${ENCRYPTION_KEY:?...}`, but nothing in `src/` ever reads
   it — the compose-level guard is the only thing making it look load-bearing.
3. **Sessions have no server-side list/fetch endpoint at all.**
   `src/handlers/sessions.l` exposes `POST /api/sessions`, `POST
   .../messages`, `DELETE .../{id}`, `POST .../model` — no `GET /api/sessions`
   or `GET /api/sessions/{id}`. The frontend (`SessionsContext.tsx`) sources
   the session list entirely from `localStorage`. Clear storage, switch
   browsers, or open a shared session link, and `SessionDetail.tsx` reports
   "Session not found" even though the transcript is still fetchable via
   `/api/sessions/{id}/messages`. This is a different angle on the
   already-tracked env-var session-store issue: even a correctly-wired
   backend store wouldn't help today, because nothing serves it back to the
   client as a list.
4. **`AgentSession` (the live session record) has no `status` field.**
   `session_manager.l`'s `AgentSession` record has
   `sessionId/repoUrl/branch/containerId/harness/model/nativeSessionId` and
   nothing else. `db_client.l`'s `SessionStatus`/`SessionEvent`/`nextStatus`
   state machine has zero callers anywhere in `src/` — not just "the SQL table
   isn't created" (already tracked) but structurally impossible to wire in
   without first adding a status field to the record that's actually used.
   `docs/PROGRESS.md`'s "Session state machine ✅ verified" is true only in
   unit-test isolation; there's no code path that could represent
   CREATED/CLONING/WARM for a real session today.
5. **Frontend auth plumbing is inert.** `lib/api.ts` reads
   `localStorage.getItem('cloud_agents_token')` for every request, but no code
   anywhere in `frontend/src` ever sets that key — no login page, no OAuth
   callback. Symmetric with the backend never checking it: the whole
   auth surface (frontend and backend) was scaffolded but never connected end
   to end.
6. **Tool-pack images are unbuildable/unreachable.**
   `docs/phase4-github-tools.md` describes selectable tool packs
   (`claude-code:rust`, `claude-code:data`), and `docker/Dockerfile.rust` /
   `docker/Dockerfile.data` exist — but `docker_manager.l`'s `imageForHarness`
   only knows `codex`/`opencode`/default, `scripts/build-docker.sh`'s `case`
   has no `rust`/`data` branch, and the Makefile has no matching target. Two
   Dockerfiles exist with no way to build or select them.

## Frontend bugs (fixed here where safe)

7. **(fixed here)** `SessionDetail.tsx` wiped the error state right after a
   failed send, before the user could ever see it — `reset()` was called
   unconditionally after every `send()`, and `useStreamMessage.send` never
   rethrows on failure. Combined with the input being cleared before the
   request even resolves, a failed send silently ate the user's prompt with
   zero feedback.
8. **(fixed here)** `SessionDetail.tsx`'s `reload()` effect had no
   staleness/cancellation guard, unlike `CommentThread.tsx`'s `active` flag
   pattern. A slow fetch for a previous session could resolve after
   navigating to a new one and overwrite the new session's transcript with
   the old one's.
9. Silent failure swallowing in `MessageBlock.tsx` (bookmark) and
   `pages/Todos.tsx` (add/toggle/remove) — errors are caught and discarded
   with no UI feedback, and `Todos.tsx`'s add form clears the draft text
   before the request completes, so a failed add loses the typed note.
10. `dangerouslySetInnerHTML` in `AnsiContent.tsx`/`Terminal.tsx` renders
    `ansi_up`'s HTML output of raw container stdout (attacker-influenceable
    via repo content/prompt injection) with no additional sanitizer —
    safety currently depends entirely on `ansi_up`'s own escaping.
11. Duplicated logic: `formatTime` copy-pasted in `MessageBlock.tsx` and
    `CommentThread.tsx`; repo-URL→label parsing duplicated in
    `SessionCard.tsx` and `SessionDetail.tsx`. No shared `lib/format.ts`.
12. No client-side URL-scheme validation in `NewSession.tsx` — the backend
    rejects non-`https://` URLs, so an SSH-style `git@github.com:...` URL
    only fails after a round trip, surfaced as a raw error string.
13. Accessibility gaps: emoji-only buttons (💬/🔖/✕) have `title` but no
    `aria-label`; comment/todo inputs rely on placeholder text with no
    associated `<label>`.
14. Hardcoded hex colors repeated across every component instead of shared
    theme constants, despite `styles.css` existing.
15. `cancelledRef` in `useStreamMessage.ts` is set up but never flipped to
    `true` anywhere — a half-built cancel feature with no cancel button.

## Docs / ops accuracy

16. **(fixed here)** No `README.md`, `LICENSE`, or `CONTRIBUTING.md` at the
    repo root — only `AGENTS.md`/`CLAUDE.md` (Lyric coding-convention docs,
    not a project overview). `lyric.toml` declares `license = "MIT"` with no
    `LICENSE` file to back it.
17. **(fixed here)** `examples/` is referenced in `CLAUDE.md` and
    `docs/lyric.md`'s project-layout section but the directory doesn't exist.
18. `docs/phase4-github-tools.md` claims "the existing PWA already has GitHub
    panels" — false; the only GitHub-related frontend code is a placeholder
    string in `NewSession.tsx`. `docs/PROGRESS.md` correctly marks this
    pending; the phase doc itself is the stale artifact.
19. `docs/phase1-core-loop.md` says ANSI codes are stripped server-side —
    the opposite of actual behavior (`streaming.l` explicitly preserves
    them; the frontend's `ansi_up` handles rendering).
20. `docker/mcp.json.template` uses `@modelcontextprotocol/server-github`
    (the real published package); `docs/phase4-github-tools.md`'s example
    config specifies `@anthropic/mcp-server-github`, which doesn't exist on
    npm.
21. `deploy/RUNBOOK.md` has a backup/restore procedure but no rollback
    procedure for a bad deploy (e.g. retagging the previous image before
    `docker compose up -d --build`, or `git checkout <prev-tag>`).
22. `deploy/docker-compose.yml` mounts `user_data:/user-home` into the `api`
    container, but nothing in `src/` reads or writes `/user-home` — an
    unused mount, likely left over from the unimplemented Phase 3 credential
    design (#2 above).
23. `docker/Dockerfile.codex`/`Dockerfile.opencode` both carry `TODO: pin`
    comments for their npm package versions; `docker/Dockerfile` installs
    `@anthropic-ai/claude-code` equally unpinned with no equivalent TODO —
    inconsistent risk-tracking across the three runner images.
24. `docs/phase5-deployment.md`'s docker-compose example (2 services, api on
    port 3000) doesn't match the real 3-service topology (api/frontend/caddy,
    no api port publish, Caddy fronts everything) — expected drift from an
    early design doc, low priority.

## Recommendation priority (if picking up more of this)

1. Real streaming (headline finding) — biggest gap between claimed and actual
   behavior, and the kind of thing a user would notice immediately.
2. Wire `GITHUB_TOKEN` into container env — cheap, mechanical, unblocks a
   documented feature that's currently just silently broken.
3. Decide the fate of Phase 3 (auth + credential encryption + per-user
   volumes): either build it for real, or explicitly re-scope the docs/UI to
   stop implying it exists (frontend auth header, `ENCRYPTION_KEY` gate,
   `docs/credentials.md`) so the gap isn't discoverable by accident.
4. Add `GET /api/sessions` (list) and `GET /api/sessions/{id}` so the
   frontend isn't solely dependent on `localStorage` for session state.
