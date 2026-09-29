# Architecture Decision Record

## ADR-001: Use `claude -p` in one-shot containers

**Context**: We need a web UI to send prompts to Claude Code and stream responses without API credits.

**Options considered**:

1. Persistent PTY with interactive `claude` – rejected because it requires a terminal UI, not chat bubbles.
2. Extract OAuth tokens and call Anthropic API directly – prohibited by ToS.
3. Official managed agents API – requires API credits, not subscription.
4. `claude -p` in ephemeral containers with `--resume` – compliant, chat-friendly, state on volume.

**Decision**: Option 4.

**Consequences**:

- Must manage container lifecycle carefully (idle recycling).
- Streaming depends on stdout of `claude` process.
- Credential management via volume mount of user’s `.claude` folder.
- Each message is a discrete invocation; no autonomous loops.

---

## ADR-002: Persistent volumes for session state

**Context**: Conversation history and workspace files must survive container restarts.

**Alternatives**:

- Database-backed state – complex, out of sync with CLI history format.
- Keep containers always running – expensive, hard to scale.

**Decision**: Docker volumes (one for user home, one per session workspace). Volumes persist; containers are ephemeral.

**Consequences**:

- Idle state is near-zero cost (disk only).
- Restoring = starting a new container with the same volumes.
- Must serialise messages per session to prevent volume corruption.

---

## ADR-003: Credential upload instead of browser OAuth flow

**Context**: The official CLI needs pre-authenticated credentials to run headlessly.

**Alternatives**:

- Implement headless OAuth – risky, may trigger anti-abuse.
- Copy already-authenticated `.claude` folder into the platform.

**Decision**: User authenticates locally, uploads the folder. The platform stores it encrypted and mounts it into containers.

**Consequences**:

- Re-upload only when refresh token expires (months).
- Security: encryption at rest and in transit is critical.
- No need to reverse-engineer OAuth endpoints.

---

## ADR-004: Single VM with Docker (no Kubernetes)

**Context**: Target is “cheapest possible” for 10-15 concurrent sessions.

**Alternatives**:

- Kubernetes – overhead, higher minimum cost.
- Serverless containers – cost unpredictability, cold starts.

**Decision**: Single cloud VM (Hetzner CX41) running Docker and the API server. Containers started on demand, stopped when idle.

**Consequences**:

- Manual scaling if needed.
- Single point of failure (acceptable for personal tool).
- Infrastructure cost ~€10-15/month.

**Status**: Superseded by ADR-008 (multi-instance topology). Remains the
supported shape until ADR-008's phase 4 ships.

---

## ADR-005: Use existing GitHub OAuth for user identity

**Context**: The frontend already authenticates users via a custom GitHub OAuth app.

**Alternatives**:

- Separate email/password auth – duplicates user management.
- Auth0/Clerk with GitHub social login – adds external dependency.

**Decision**: Re-use the GitHub OAuth token as the API authentication mechanism.

- Frontend sends token in `Authorization: Bearer <github_token>` header.
- API server validates it by calling `https://api.github.com/user`.
- The returned GitHub user ID is the stable tenant key.

**Consequences**:

- Each API call requires synchronous token validation (cached for token lifetime).
- No persistent user records needed.
- Credentials are stored keyed by GitHub user ID, encrypted with server-side key.

---

## ADR-006: Keep the credential vault write-only

**Context**: The Integrations page needs provider keys in the browser (live
model discovery, GitHub repo/PR/CI panels), but the vault never returns a
stored value. This forces a second, local copy of each connected key in
`localStorage`, and the question arose whether the vault should simply become
read-write so the UI could fetch keys on demand instead.

**Alternatives**:

- Read-write vault (`GET /api/credentials/{name}` returns the secret) —
  removes the second copy, but converts every stored secret into something
  exfiltratable in one authenticated GET. Any XSS, leaked API token, or
  malicious browser extension could then enumerate and download the entire
  vault, including secrets the UI never needs (e.g. deploy keys injected only
  into containers). It also breaks the current auditability guarantee that a
  secret, once stored, only ever flows server→container.
- Backend proxy endpoints (`/api/github/*`, `/api/models/*`) that use vault
  credentials server-side — the browser never holds a key at all. This is the
  best end state. *Update (GitHub OAuth PR):* outbound HTTPS with request
  headers is now proven from the backend via direct `HttpWebRequest` externs
  (`src/github_api.l`, used by the OAuth flow), so this migration is
  unblocked and is the recommended next step. *Update (proxy PR): landed —
  see below.*
- Local-copy-on-connect — the vault stays write-only; the Integrations page
  keeps a browser-side copy of only the keys the user explicitly connects,
  documented with mitigations in `docs/credentials.md`. Now the *fallback*
  path rather than the only path.

**Decision**: Keep the vault write-only. **The proxy migration has landed**:
`GET /api/github/repos/{page}`, `/api/github/repos/{owner}/{repo}`,
`/api/github/pulls/{owner}/{repo}/{branch}`,
`/api/github/checks/{owner}/{repo}/{branch}` and `/api/models/{harness}`
(`src/handlers/proxy.l`) call GitHub and the model providers server-side with
vault keys and pass the raw JSON through; the frontend
(`lib/github.ts`/`lib/models.ts`) tries the proxy first and keeps the
browser-side copies only as a fallback (no vault key stored, an older
backend without the routes, or a branch name with `/` that doesn't fit the
proxy's single path segment). Browser-held provider keys are therefore now
**optional** for the repo browser, PR/CI panels and live model discovery.

**Consequences**:

- Vault compromise via the web surface stays limited to *writing* secrets,
  never reading them: the proxy endpoints return provider *responses*
  (listings), never the keys themselves; a hostile write is visible (names
  are listable) and recoverable (rotate + overwrite).
- The browser holds at most the four connect-able provider keys, and only if
  the user explicitly connects them for the fallback path; each is revocable
  at the provider, and "Disconnect" removes the local copy without touching
  the vault. With vault keys present, connecting locally is unnecessary.
- Two copies of a connected key exist only for users still relying on the
  fallback; the direct browser path (and this ADR's remaining trade-off) can
  be removed entirely once slashed-branch routing lands and old backends age
  out.

---

## ADR-007: Pre-accept the Claude harness's workspace trust dialog

**Context**: Claude Code asks interactively whether to trust a project
directory before honoring `settings.json`'s `permissions.allow` entries or
auto-loading other trust-gated project config (notably a repo-root
`.mcp.json`). `docker/entrypoint.sh` runs `claude -p` non-interactively, so
that prompt can never be answered — every run printed a warning and fell
back to unconfigured defaults (fixed in #705 by pre-accepting `/workspace`
in `~/.claude.json` before invoking `claude`).

**Consequence worth recording** (raised in #705's review, #711):
`/workspace` is populated by cloning `REPO_URL`, which is user-supplied.
Pre-accepting its trust means that if a cloned repo ships its own root
`.mcp.json`, Claude Code will now auto-load it and start whatever MCP
servers it declares, with no human confirmation — previously impossible
(the dialog blocked everything), now live.

**Decision**: Accept this. It is not a novel exposure for this project:
`docker/entrypoint-gemini.sh` already runs its harness with `--yolo`
("the container itself is the sandbox, same trust model as the other
harnesses") — an even broader auto-approval than a trust dialog would
have gated. The Claude harness now matches that existing precedent rather
than being the one harness still (uselessly) blocked by a prompt nothing
can answer.

**Consequences**:

- A malicious or compromised `REPO_URL` can register and run MCP servers
  inside the runner container with no human review step, same as it
  already could invoke arbitrary tools once the harness starts working the
  repo.
- Containment still rests on the container being the trust boundary (fresh
  per session, no host access beyond what's explicitly mounted/exposed) —
  if that sandboxing assumption ever changes, this decision needs
  revisiting alongside `entrypoint-gemini.sh`'s `--yolo`.

---

## ADR-008: Multi-instance topology: stateless API tier, runner hosts, dedicated Postgres

**Status**: Accepted (direction). Supersedes ADR-004. Implementation is
phased (see Migration); each phase lands as its own spec + PR.

**Context**: cloud-agents is moving from a personal single-VM tool to a
multi-tenant service that feeds Testamur (capture, checkpoints, graph
ingest) and must survive deploys and single-node loss. ADR-004's shape
couples everything to one host:

- One API process drives Docker through the local socket
  (`src/docker_manager.l`) and owns each live run: `streamSessionMessage`'s
  poll loop reads the container log, renders it and persists
  `session_events` in-process, so a deploy or crash drops in-flight runs.
- State is one SQLite file with a TEXT-only driver (`src/db/sqlite_driver.l`);
  artifacts and attachments are local directories; per-session workspaces
  and per-user harness homes (`workspaceVolumeBindFor`/`homeVolumeBindFor`)
  are named volumes on that host. Until #1135 the DB lived in the container
  layer and every redeploy lost all sessions.
- Periodic work (`/api/maintenance/{reap,trigger-jobs,drain-graph-ingest,
  observe,ledger-sync}`) is operator-polled and assumes one caller.
- Tenancy is by naming convention only (`gh-<id>` volume keys, `user_id`
  columns); there is no database-enforced isolation. Auth fails open when
  unconfigured (CAPABILITY_AUDIT WP3).

**Decision**:

1. **Stateless API tier.** N identical API instances behind a load balancer.
   No API instance holds run state, Docker access or local files. Any
   instance can serve any request, including the SSE/poll output stream,
   which reads from Postgres.
2. **Runner hosts.** Docker moves to dedicated runner hosts, each running a
   small `cloud-agents-runner` agent (Lyric, in this repo) alongside the
   Docker daemon. The agent:
   - long-polls the API's internal runner endpoints for work, authenticated
     with a per-host credential, and claims runs by lease;
   - creates, watches and reaps its own containers (today's
     `docker_manager.l` logic moves here);
   - reads the container log, parses it with the existing
     `CloudAgents.Capture` core and posts hash-chained event batches to the
     API (idempotent on `(session_id, seq)`), renewing its lease as it goes.
     After an agent restart it resumes from the last acknowledged `seq` by
     re-reading the container log.

   Runner hosts authenticate with mTLS client certificates issued by an
   internal CA, bound to the host's identity, short-lived and rotated
   automatically, so a stolen credential expires on its own and one host
   cannot act as another. Phase 2's single shared credential is the interim
   until this lands in phase 4.

   Runner hosts never receive Postgres credentials. They execute
   attacker-influenced code (ADR-007), so a compromised host must not be able
   to read or write other tenants' rows. The API is the only schema owner and
   the only writer.
3. **Session placement.** A session is pinned to the runner host that holds
   its workspace volume (`sessions.runner_host_id`); follow-up runs are only
   offered to that host. After each run finishes, the runner agent
   snapshots the workspace volume (compressed tar) to object storage under
   the tenant's prefix, keyed by session and run. The snapshot is taken
   after the run is reported finished, so it is off the user's critical
   path. Snapshots are encrypted at rest (workspaces can hold secrets), the
   latest few per session are retained, and they are deleted with the
   session. If the host is lost, the session is restored on another host
   from its latest snapshot; changes made since that snapshot (i.e. during
   an in-flight run) are lost. The session moves to `WORKSPACE_LOST` only
   when no snapshot exists; the user can then re-attach it to a new host,
   which re-clones the repo.
4. **Run lifecycle in Postgres.** A `runs` table carries the state machine
   (`queued -> claimed -> running -> finished | failed | lost`), a lease
   expiry and the owning host. Claims use `SELECT ... FOR UPDATE SKIP
   LOCKED`. The API marks a run whose lease lapses as `lost`: it records
   this in the ledger and surfaces it to the user; it never silently
   retries a run that may have had side effects.
5. **Dedicated Postgres instance** for cloud-agents. It is separate from
   Testamur's, so the two services scale, fail and migrate independently.
   Data reaches Testamur only through its existing ingest API
   (`graph_ingest_outbox`); there are no cross-database queries. Schema
   conventions follow Testamur ADR-0019:
   - a `tenant_id` column leads every tenant-owned key;
   - row-level security is enforced (`FORCE ROW LEVEL SECURITY`) and keyed
     on a transaction-local `app.current_tenant` setting;
   - the service connects as a non-owner, non-superuser role.

   Access goes through `Lyric.Db` + Npgsql, behind the existing
   `db_client.l`/`repository.l` seam. Columns are properly typed; the
   TEXT-only convention is retired.
6. **Object storage** (S3-compatible) holds attachment and artifact bytes.
   Before a run, the runner agent downloads the session's attachments into
   a host directory and mounts it read-only, as today. Artifacts reach the
   API through the existing callback path and are stored in the object store.
7. **Harness credentials follow the user, not the host.** Per-user harness
   homes stop being long-lived host volumes. At run start the runner agent
   materialises the credentials the run needs from the encrypted vault,
   delivered by the API over the claim response for that run only, and
   removes them at run end.
8. **Callbacks.** The MCP shim in each container keeps calling the API with
   its per-run callback token, now via the load-balanced API URL rather than
   a same-host address. Permission, secret and question requests already
   live in the database, so any instance can answer them.
9. **Periodic work.** The maintenance endpoints stay operator-polled; no
   in-process timer is introduced. Each one claims its work items with
   `SKIP LOCKED` (or a Postgres advisory lock for whole-pass jobs), so any
   number of concurrent callers is safe. Container reaping moves into the
   runner agent, which knows its own containers.
10. **Tenant = organisation.** The RLS `tenant_id` is an organisation id,
    not a user id.
    - `tenants` and `memberships(tenant_id, user_id, role)` tables, with
      roles `owner`, `admin` and `member`. A user may belong to several
      organisations.
    - The active organisation is selected per request and validated against
      the caller's memberships before `app.current_tenant` is set; it is
      never taken from the request unchecked.
    - Sessions, profiles, jobs, ledger entries and capture data belong to
      the organisation and record their creator. Which members can see a
      given session is an API-level product rule on top of RLS.
    - User-scoped secrets (harness credentials, GitHub tokens) carry both
      `tenant_id` and `user_id` and stay readable only by their owner, even
      within the organisation (ADR-006's write-only vault is unchanged).
    - Existing users each become the single owner of a personal
      organisation during the phase 1 export, so personal use keeps working.
11. **Fail-closed auth** (CAPABILITY_AUDIT WP3) is a precondition for the
    multi-tenant deployment. Unauthenticated mode becomes an explicit
    single-node opt-in.

**Alternatives considered**:

- *Sticky API+Docker nodes* (several ADR-004 VMs with session-affinity
  routing). Least code change, but each node is still a single point of
  failure for its sessions and its in-flight runs. It also keeps run
  ownership in API processes, so deploys still drop runs.
- *Managed container platform* (ECS/Fargate, Fly Machines, Kubernetes Jobs)
  with network-attached workspaces. This gives the best elasticity, but it
  is the largest rewrite, changes the cost model ADR-004 optimised for, and
  puts workspace I/O on network storage. It can be revisited later: the
  runner-agent protocol is the seam such a backend would implement.
- *Runner agents writing to Postgres directly*. Simpler plumbing, but it
  places database credentials on hosts that run untrusted code and gives
  the schema two writers.
- *Sharing Testamur's Postgres* (same cluster or same database). This
  couples migrations, RLS policies and blast radius across two services
  for no current benefit; the ingest API is already the integration seam.

**Migration** (each phase is independently shippable, and the system is
deployable after each):

0. Persist state across deploys (#1135). Done.
1. Postgres behind the repository seam, still single-node: typed schema,
   organisation tenants and memberships, `tenant_id` + RLS, a one-shot SQLite-to-Postgres export tool, and live-PG
   CI suites. SQLite remains only until the export has been run on the
   production instance, then its driver is deleted rather than kept as a
   second backend.
2. The `runs` table, the runner agent and the internal runner protocol,
   co-located with the API on today's VM, authenticated with a single
   runner credential held as a deployment secret. Moving run ownership out of the
   API process means API deploys stop dropping runs, before any
   multi-host work.
3. Object storage for attachments, artifacts and workspace snapshots;
   credentials materialised per run.
4. Split runner hosts from the API tier; run N API instances behind a load
   balancer, with session placement, restore-from-snapshot and
   `WORKSPACE_LOST` handling, and mTLS runner-host credentials replacing the
   phase 2 shared credential.
5. Fail-closed auth ships no later than the first multi-tenant deployment;
   it can land at any point before then.

**Consequences**:

- API deploys and API instance loss no longer interrupt runs (from phase
  2). Runner host loss interrupts only that host's runs and workspaces.
  The loss is explicit (`lost`/`WORKSPACE_LOST`), never silent.
- Tenant isolation is enforced by the database, not by naming conventions.
- New operational surface: a Postgres instance (backups, PITR, upgrades), an
  object store, runner-host provisioning and per-host credentials.
- Workspace snapshots add object-storage cost proportional to workspace
  size times retained snapshots, and a background upload after every run.
- Organisation tenancy adds membership management and an active-organisation
  selector to the UI and API.
- `ENCRYPTION_KEY` must be identical across API instances; it moves to the
  deployment's secret manager.
- The run path gains a network hop (runner agent to API) for event
  batches. Event ordering and idempotency rest on the existing hash-chained
  `(session_id, seq)` capture model.

**Resolved questions** (owner decisions, 2026-09-29):

1. Workspaces are snapshotted to object storage at run end, so a session
   survives host loss (decision 3).
2. Runner-host credentials are bound to host identity via mTLS, issued and
   rotated automatically (decision 2, phase 4).
3. Tenants are organisations with members, not individual GitHub users
   (decision 10).

**Open questions**:

1. Should output reach the UI by DB polling, or by Postgres `LISTEN/NOTIFY`
   fan-out to the SSE stream? Current plan: start with polling, using the
   same indexed after-`seq` cursor query that
   `GET /api/sessions/{id}/events` already uses, behind a small reader
   interface. Move to `LISTEN/NOTIFY` only if polling load is measurably a
   problem, and only once `Lyric.Db` supports notifications on a dedicated
   connection (unverified today).
2. Where does organisation membership come from: GitHub organisation
   membership synced at sign-in, cloud-agents-native organisations with
   invitations, or both? This must be settled before the phase 1 schema is
   final.
