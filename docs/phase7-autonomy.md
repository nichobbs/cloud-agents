# Phase 7 — Cross-session autonomy: memory, notify, artifacts, per-profile tools

Status: in progress. This doc scopes the phase-7 autonomy work and its
slices. Slice 1 (**repo-scoped memory** — `remember` / `recall`) lands
first; the remaining slices (notify, repo-scoped artifacts, per-profile
tool enablement) follow the same shim↔host callback pattern phase 6
established and are specced here so each can land independently.

Builds directly on phase 6 (`docs/phase6-mcp-callbacks.md`): the same
in-container `cloud-agents-shim` MCP server, the same per-session callback
bearer token, the same `POST/GET /api/sessions/{id}/callbacks/*` channel,
the same `isContainerCallbackRoute` auth split. Phase 7 adds no new
transport — every new tool is another endpoint on the existing
authenticated channel plus another `addTool` in the shim.

## 1. Problem

Phase 6 gave a running container a way to reach the human *right now*
(permissions, questions, secrets). Two gaps remain:

1. **No memory across sessions.** Every container is fire-and-forget and
   every session starts cold. An agent that spent a session learning a
   repo's build quirks, test layout, or deploy steps throws all of it
   away when the container dies. The next session on the *same repo*
   re-learns everything from scratch. There is no store keyed to the
   repo that a later session can read back.
2. **No reach when the tab is closed.** The only push to the human is
   SSE (`CloudAgents.Streaming`), which requires an open browser tab
   holding the session stream. An agent working autonomously for a long
   time has no way to say "I'm done" or "I'm blocked" to a human who has
   navigated away.

Phase 7 addresses (1) with repo-scoped memory and (2) with a `notify`
tool, and adds the operator control the growing tool surface now needs:
**per-profile tool enablement**.

## 2. Design principles

- **Reuse the phase-6 channel verbatim.** No new Docker capability, no
  new transport, no new auth mechanism. Each tool is one host handler +
  one route + one shim tool, exactly as `add_followup_task` is.
- **Repo-scoped, not session-scoped, where it earns its keep.** Memory
  and (optionally) artifacts are keyed to a stable repo identifier so a
  future session on the same repo inherits them. This is the headline
  behaviour the user asked for: "save having to learn each time."
- **Scoped by owning user, too.** A repo key alone is not the grain:
  memory is keyed `(user_id, repo_key, key)` so one user's accumulated
  repo memory never leaks into another user's sessions on the same public
  repo. `user_id` is the session's owner, already on `sessions`.
- **Honest about enforceability.** Where a proposed tool cannot be
  enforced with today's plumbing (the network-allowlist tool — see §9.2),
  it is specced as deferred with the concrete plumbing it needs, not
  shipped as a stub that pretends to work.

## 3. Repo identity and scoping

There is no stable `owner/repo` key in the schema today. A session's
primary repo is a raw `repo_url TEXT` column on `sessions`
(`src/db/db_client.l`); a session can also touch several repos via
`session_repos` (max 20). Phase-7 memory is scoped to the session's
**primary repo** (`sessions.repo_url`) in v1; multi-repo memory is a
follow-up (§11).

The stable key is derived by normalizing the git URL, in a pure,
unit-testable package `CloudAgents.RepoKey` (`src/repo_key.l`) — pure and
standalone for the same reason `CloudAgents.NetworkPolicy` is: a
`@test_module` cannot reach anything behind an `async func` package, so
the logic lives outside `CloudAgents.Docker` where a test can import it.

`repoKeyOf(url)` normalizes to `host/owner/repo`, lowercased:

- strip a `scheme://` prefix (`https://`, `http://`, `ssh://`, `git://`);
- strip `user[:password]@` credentials;
- rewrite the `scp`-style `git@host:owner/repo` form to `host/owner/repo`
  (the `:` after the host becomes `/`);
- strip a trailing `.git` and any trailing `/`;
- lowercase the whole thing.

Examples (all → `github.com/nichobbs/cloud-agents`):

```
https://github.com/nichobbs/cloud-agents.git
https://github.com/nichobbs/cloud-agents
git@github.com:nichobbs/cloud-agents.git
ssh://git@github.com/nichobbs/cloud-agents.git
https://x-access-token:TOKEN@github.com/nichobbs/cloud-agents
```

A URL that does not parse to a non-empty key (empty, or no path segment)
yields `""`; the host rejects a memory call whose session has no usable
repo key with a clear error rather than writing an unscoped row. Keying
on `host/owner/repo` rather than bare `owner/repo` keeps a `github.com`
repo distinct from an identically-named `gitlab.com` one.

## 4. Slice 1 — repo-scoped memory (`remember` / `recall`)

The headline. A small key/value store scoped to `(user_id, repo_key)`
that persists across sessions.

### 4.1 Tools

- `remember(key, value)` — upsert one entry for this session's repo.
  Returns a short confirmation. Overwrites an existing `key`.
- `recall(key?)` — read memory for this session's repo. With `key`,
  returns that entry's value (or a "no memory under that key" message).
  Without `key`, returns every entry (key + value) for the repo, so an
  agent can load the whole accumulated context at the start of a session
  in one call — the "pick it up next time" flow.
- `forget(key)` — delete one entry for this session's repo (#592), so
  stale notes can be pruned and a slot freed when the entry cap is
  reached. Idempotent: forgetting an absent key succeeds (reports
  "absent"), it is not an error.

### 4.2 Host side

- Migration `0013_repo_memory`: table
  `memories(id, user_id, repo_key, mem_key, value, created_at, updated_at)`
  with `UNIQUE(user_id, repo_key, mem_key)`, plus an index on
  `(user_id, repo_key)`. All columns `TEXT` (schema convention).
- `CloudAgents.Repository`: `upsertMemoryCapped(userId, repoKey, key,
  value, maxEntries)` (a single atomic
  `INSERT … SELECT … WHERE … ON CONFLICT DO UPDATE` that enforces the cap
  race-free), `listMemory(userId, repoKey)`, `getMemory(userId, repoKey,
  key)` (single-key lookup, #590), and `deleteMemory(userId, repoKey,
  key)`.
- `CloudAgents.Callbacks`:
  - `POST /api/sessions/{id}/callbacks/memory` `{key, value}` —
    container-originated (`authorizeCallbackToken`), resolves the
    session's `user_id` + normalized `repo_key`, upserts. Bounded key
    (256) and value (65,536) lengths — character counts, not bytes — and a
    per-repo cap of 256 distinct
    keys (overwrites of an existing key are always allowed; only a new key
    past the cap is rejected) so the store can't grow unbounded.
  - `GET /api/sessions/{id}/callbacks/memory` — container-originated. With
    no `key` query param, returns all entries for the repo as JSON
    (`recall` with no key reads this). With `?key=`, does a targeted
    single-row lookup instead (#590) and returns just that one entry (or
    none) — `recall(key)` uses this rather than fetching the whole store
    and filtering client-side.
  - `POST /api/sessions/{id}/callbacks/memory/forget` `{key}` —
    container-originated, deletes one entry (`forget`, #592). Idempotent.
  - `GET /api/sessions/{id}/memory` — user-originated
    (`requireOwnedSession`), so the UI can show/inspect a repo's memory.
- No SSE event: memory is not a live-notification surface. The `memories`
  table's `updated_at` is its own audit trail (who/when is implicit in
  `user_id`), consistent with phase 6's per-feature-row audit model
  (there is no general audit table).

### 4.3 Shim side

Mirrors `add_followup_task` field-for-field:

- `CloudAgents.Shim.V2Transport`: `RememberRequest{key,value}`,
  `MemoryEntry{key,value}`, `MemoryListResponse{entries}`,
  `ForgetRequest{key}` / `ForgetResponse{key,status}` wire records;
  `remember`/`recallAll`/`recallByKey`/`forget` on the
  `V2CallbackTransport` interface + the `HttpV2CallbackTransport` impl
  (`POST`/`GET …/callbacks/memory`, `GET …/callbacks/memory?key=` for a
  single entry (#590), `POST …/callbacks/memory/forget`).
- `CloudAgents.Shim.V2Client`: `remember(transport, key, value)` (single
  POST), `recall(transport, keyOpt)` (a single targeted GET via
  `recallByKey` when a key is given, or `recallAll`'s whole-list GET when
  it isn't), and `forget(transport, key)` (single POST).
- `CloudAgents.Shim.V2Tools`: `RememberTool` / `RecallTool` / `ForgetTool`
  with their schemas; registered in `shim/src/main.l` via `addTool`.

## 5. Slice 2 — `notify(summary, level?)`

Fire-and-forget push to the human that an autonomous run reached a
milestone (done / blocked / needs input).

Today this is **SSE-only**: there is no web-push / VAPID / FCM /
service-worker-push infrastructure in the repo (confirmed — zero matches
for `pushManager`/`push_subscriptions`/VAPID). `notify` v1 therefore:

- `POST /api/sessions/{id}/callbacks/notify` `{summary, level}` →
  persists a `notifications(id, session_id, level, summary, created_at,
  read_at)` row and emits a new `notification` SSE event on the session
  stream, exactly like `progress_update` does.
- Shim `notify(summary, level?)` tool — fire-and-forget, returns
  immediately. `level` ∈ {info, done, blocked} (default info).

A UI badge / list reads the rows via a user-auth
`GET /api/sessions/{id}/notifications`.

**True out-of-tab push (web-push) is a follow-up (§11):** it needs a
`push_subscriptions` table, a VAPID keypair, the service worker's
`push`/`notificationclick` handlers, and a host-side sender. The PWA
service worker (phase-PWA, `frontend/src/pwaOptions.ts`) is the natural
home for the client half but carries no push code yet. `notify`'s row +
SSE model is forward-compatible: adding web-push later just adds a second
delivery of the same `notifications` row.

## 6. Slice 3 — repo-scoped artifacts

Phase-6 artifacts are session-scoped only (`artifacts.session_id`, bytes
at `artifactsBaseDir()/<sessionId>/<storedName>`). Slice 3 adds an
optional repo scope so a build output or report survives into later
sessions on the same repo:

- Migration `0015`: add `repo_key TEXT NOT NULL DEFAULT ''` to
  `artifacts` + an index on `(repo_key)`. Existing rows keep `''`
  (session-only), so this is backward-compatible.
- `report_artifact` gains an optional `scope` argument (`session`
  default, or `repo`). A `repo`-scoped artifact is written under
  `artifactsBaseDir()/repo/<repoKey>/<storedName>` and its row carries
  the `repo_key`; `session`-scoped keeps today's exact behaviour.
- `GET /api/sessions/{id}/artifacts` continues to list this session's
  artifacts; a new user-auth `GET /api/repos/{repoKey}/artifacts` (or a
  query flag) lists a repo's durable artifacts. Download is unchanged
  except for the base-dir branch.

Kept a separate slice because it touches the artifact download path and
the on-disk layout; memory (slice 1) is the cleaner first landing.

## 7. Slice 4 — per-profile tool enablement

The user's requirement: *a profile should define which tools are
available*. The existing per-profile credential-grant mechanism is the
exact shape to mirror.

Today a `Profile` has `credentialMode` ∈ {all, selected} plus a
`profile_credentials(profile_id, user_id, credential_name)` join table;
`docker_manager.l` injects only the granted credential names in
`selected` mode (fail-closed). Phase 7 mirrors this for tools:

- Add `tool_mode TEXT NOT NULL DEFAULT 'all'` to `profiles` and a
  `profile_tools(id, profile_id, user_id, tool_name, UNIQUE(profile_id,
  tool_name))` join table (migration `0016`).
- `all` (default) → every shim tool is registered, preserving today's
  behaviour exactly. `selected` → only the named tools are registered.
- **Enforcement point:** `docker_manager.l` resolves the session's
  profile at container creation and injects
  `CLOUD_AGENTS_ENABLED_TOOLS` (a comma-separated allowlist) into the
  container, the same place and way it injects resolved credentials. The
  shim's `main.l` reads it and only `addTool`s a tool whose name is in
  the list; an empty/unset value means "all" (default-on, so a
  pre-phase-7 container or an `all`-mode profile is unchanged).
- **Defense in depth (hardening follow-up):** the host callback handlers
  can additionally reject a disabled tool's endpoint (403) by consulting
  the same profile policy, so a tampered container cannot re-enable a
  tool the operator disabled. v1 relies on the shim not registering it;
  the host-side gate is tracked as a follow-up.

The tool names are the stable MCP names already in `shim/src/main.l`:
`request_permission`, `ask_user`, `report_progress`, `request_secret`,
`add_followup_task`, `report_artifact`, and the phase-7 additions
(`remember`, `recall`, `notify`). Enablement is per-name.

## 8. Slice 5 — repo-scoped task list (`add_task` / `list_tasks` / `complete_task`)

A cross-session, repo-scoped **worklist with a done-state**. Where memory
(slice 1) stores durable *facts* an agent recalls, this stores *actionable
work items* that outlive a session: one session leaves "still need to
migrate the auth module," a later session on the same repo lists the open
items, does one, and marks it done.

**Distinct from phase-6 `add_followup_task`** (deliberately not a rename of
it). `add_followup_task` writes a **session-scoped** todo — a note *for the
human* on the current session (`CloudAgents.Repository.addTodo` →
`listTodos(sessionId)`), with no cross-session visibility and no
agent-driven completion. This slice is a **repo-scoped, agent-facing shared
backlog** with an open→done lifecycle. Both stay; the doc and tool
descriptions call out the difference so an agent picks the right one (leave
a note for the human on this run → `add_followup_task`; queue/track work for
future sessions on this repo → `add_task`).

Design mirrors the memory slice almost exactly (same callback channel, same
`(user_id, repo_key)` scoping, same auth split):

- Migration `0014_repo_tasks`: table `repo_tasks(id, user_id, repo_key,
  description, status, created_at, updated_at)` where `status ∈ {open,
  done}`, index on `(user_id, repo_key, status)`. A per-repo cap of 256
  entries, same value as memory's cap for consistency — but **counting
  OPEN tasks only, not lifetime total**: this is the one place the cap
  logic genuinely differs from memory's. Memory's cap counts every distinct
  key ever written (an overwrite doesn't grow it, but nothing ever shrinks
  it either); a task backlog needs the opposite property, since `done` tasks
  are history, not backlog — completing a task must free capacity for a new
  one, or a long-running agent would eventually deadlock itself out of being
  able to add any further work. The atomic capped insert
  (`insertTaskCappedSql`) is correspondingly simpler than memory's: since
  `add_task` always creates a brand-new row (there is no natural unique key
  to `ON CONFLICT` against, unlike memory's `mem_key`), the guard is a plain
  `WHERE (SELECT COUNT(*) FROM repo_tasks WHERE … AND status = 'open') <
  256`, with no overwrite branch.
- Host (`CloudAgents.Callbacks`): `POST …/callbacks/tasks` `{description}`
  (create, open), `GET …/callbacks/tasks?status=` (list, container-auth),
  `POST …/callbacks/tasks/{tid}/complete` (mark done), and a user-auth
  `GET /api/sessions/{id}/tasks` for the UI. Resolves owner + repo_key
  exactly as memory does. `complete_task` is idempotent (completing an
  already-done task is a success no-op, not an error) and repo-scoped (a
  task id only completes within its own (user, repo) scope — a task id that
  exists but belongs to a different scope 404s exactly like an absent id,
  mirroring `downloadArtifactHandler`'s session-scope check).
- Shim: `add_task(description)`, `list_tasks(status?)`,
  `complete_task(id)` tools, same transport/client/tool structure as
  `remember`/`recall`/`forget`.

No SSE event needed (the UI polls, like todos already do); the `repo_tasks`
row's `status` + `updated_at` are its own audit trail.

**Recommendation: yes, worth building** — it's the natural companion to
memory for genuinely autonomous multi-session work, it's low-risk (a
near-copy of the memory slice), and it fills a real gap (`add_followup_task`
can't be completed by an agent or seen by a later session). Sequenced after
the memory slice merges to avoid migration-number churn.

## 9. Two open questions answered

### 9.1 Do we need a shell / bash MCP tool?

**No.** Shell execution is a first-class, built-in capability of every
coding-agent CLI this project runs (Claude Code's `Bash` tool;
gemini/codex/opencode equivalents) — it is not something an MCP server
needs to provide. Crucially, that built-in shell is *already governed by
the phase-6 permission flow*: with callbacks active, `claude` runs with
`--permission-prompt-tool mcp__cloud-agents__request_permission`, so a
`Bash(...)` call the static allowlist doesn't cover routes to the human
via `request_permission` (`docs/phase6-mcp-callbacks.md` §3, §8).

Adding a `run_shell` MCP tool would be strictly worse: it would
duplicate a first-class capability *and* bypass the harness's own
permission gating (an MCP tool call is not itself subject to
`--permission-prompt-tool`), widening the exact attack surface phase 6
narrowed. So: shell stays built-in and permission-gated; no MCP tool.

### 9.2 A "request to whitelist a destination" tool in a restricted env?

**Not enforceable today — deferred, needs new plumbing.** The restricted
network environment is only coarsely built out. `CloudAgents.NetworkPolicy`
(`src/network_policy.l`) resolves a profile's policy to a *Docker
NetworkMode*, nothing finer:

- `none` → fully isolated; `full`/no-profile → default bridge (full
  egress); `restricted` → joins the operator-provisioned
  `CLOUD_AGENTS_RESTRICTED_NETWORK` Docker network, else **fails closed
  to "none"**.
- The proxy env vars (`proxyEnvForPolicy`) are explicitly *advisory* — "a
  process can ignore them." Any actual host/domain filtering lives in the
  operator's egress proxy on that restricted network, **outside this
  repo**. There is no per-session, per-destination allowlist the host
  controls, and no API to add one.

So a `request_destination(host)` tool has nothing to write to that would
change what the container can reach. Making it real needs new plumbing:
either (a) a host-managed per-session allowlist table that the egress
proxy consults live (proxy → host authorization call per connection), or
(b) the host reconfiguring the proxy's allowlist and signalling it to
reload. Both are a meaningful piece of infrastructure and a security
surface in their own right (an agent asking to open egress to an
arbitrary host is precisely the exfiltration channel the restricted mode
exists to close), so this is out of scope for phase 7's first tools and
tracked as a design item (§11). The honest status is: the restricted env
enforces *coarsely* (join-a-network / fully-isolated) and delegates fine
filtering to an out-of-repo proxy, so there is no in-repo knob a tool
could turn yet.

## 10. Sequencing (slices)

1. **Slice 1 — memory** (`remember`/`recall`): migration `0013`,
   `CloudAgents.RepoKey`, repository + handlers + routes, shim
   transport/client/tools/registration, tests, docs. *Lands first —
   this PR.*
2. **Slice 2 — notify**: migration `0015` (`notifications`), the
   `notification` SSE event, handlers + shim tool, tests.
3. **Slice 3 — repo-scoped artifacts**: migration for `artifacts.repo_key`,
   `report_artifact` `scope` arg, repo-artifact list endpoint.
4. **Slice 4 — per-profile tool enablement**: `profiles.tool_mode` +
   `profile_tools`, `docker_manager.l` `CLOUD_AGENTS_ENABLED_TOOLS`
   injection, shim conditional registration, profile UI/API surface.
5. **Slice 5 — repo-scoped task list** (`add_task` / `list_tasks` /
   `complete_task`): migration `0014` (`repo_tasks`), handlers + shim
   tools, tests. A near-copy of the memory slice with an open→done
   status; see the "Slice 5" section above.

   (Slices 3 and 4 hadn't merged yet when slice 5 landed, so the actual
   merge order claimed `0014`/`0015` out of the sequence sketched above —
   `repo_tasks` ended up as `0014` and `notifications` as `0015`, both
   renumbered post-merge to keep the migration array's version-prefix ==
   array-position invariant `allMigrations()`'s own doc comment requires;
   see issue #609.)

Each slice is testable Docker-free the same way phase 6 is: handler
tests hit the endpoints in-process; the shim's client is tested against
the in-memory `V2CallbackTransport` fake; `scripts/e2e-http.sh` can gain
a real-HTTP leg per tool.

## 11. Deferred / future

- **Web-push notify** — `push_subscriptions` + VAPID + service-worker
  `push`/`notificationclick` + host sender, so `notify` reaches a closed
  tab / a phone. `notify`'s row+SSE model is forward-compatible.
- **`schedule_wake(delaySeconds, message)`** — let a container ask to be
  re-invoked later with a new message ("check on this in 10 min"), for
  genuinely autonomous multi-step work. Needs a host-side scheduler that
  re-spawns a turn against the session; larger than a callback tool.
- **`request_capability`** — a coarser, session-scoped capability grant
  (elevate the whole session once) as an alternative to per-call
  `request_permission`. A profile/permission-rule extension.
- **`request_destination`** — the network-allowlist tool from §9.2, once
  the restricted-env proxy grows a host-controlled allowlist.
- **Multi-repo memory** — scope memory to any repo in `session_repos`,
  not just the primary `repo_url`.
- **`spawn_subagent`** — let a run fan out a scoped sub-task into its own
  container. Depends on the scheduler work above.

## 12. Doc/book sync

Per `AGENTS.md`, shipped tools update the relevant docs. Each slice
updates this file's status line and, where the tool is user-visible, the
session/tooling docs. The shim tool list in this doc and
`shim/src/main.l` must stay in sync.
