# Phase 11: Postgres and organisation tenancy (ADR-008 phase 1)

Status: spec approved (merged in #1140); implementation in progress, slice by slice (§9).

Implements phase 1 of ADR-008 (`docs/architecture-decisions.md`): move the
store from SQLite to a dedicated Postgres instance behind the existing
repository seam, still on a single node, and introduce organisation tenants
with database-enforced isolation. Multi-host concerns (runner agent, object
storage, load balancing) are later phases and out of scope here.

## 1. Goals and non-goals

Goals:

- All persistent state in Postgres, with typed columns. The TEXT-only
  convention (`db_client.l`: "TEXT-for-numerics") is retired.
- Every tenant-owned row carries `tenant_id`, an organisation id, and is
  isolated by forced row-level security under a non-owner application role.
  This follows Testamur ADR-0019.
- Organisation membership from two sources: GitHub organisation membership
  synced at sign-in, and native organisations with invitations.
- No data migration: production holds no data worth keeping, so the
  cut-over starts on an empty database (owner, 2026-10-01; §7).
- Live-Postgres test suites in CI, including a two-tenant isolation proof.
- SQLite driver and SQLite-specific SQL deleted once production has been
  migrated (ADR-008: no second backend kept).

Non-goals (later phases or explicitly deferred):

- Runner hosts and object storage (ADR-008 phases 2 to 4). Several API
  instances are supported from this phase (§5.3a); until the runner agent
  exists, a run is driven by the API instance that started it.
- Organisation-wide session sharing. Phase 11 keeps today's visibility rule:
  a user sees only the sessions they created, now also scoped to the active
  organisation (§5.4). Sharing is a later product decision.
- Managed Postgres. Phase 11 targets a Postgres service in the app's own
  compose stack on the existing VM (§8); the move to managed Postgres happens at ADR-008 phase 4
  and must be a connection-string change only (§8).

## 2. Current state (what is being replaced)

- `CloudAgents.Sqlite` (`src/db/sqlite_driver.l`): a hand-rolled
  Microsoft.Data.Sqlite binding exposing `execute(sql)`,
  `executeTransaction(sqls)` and `query(sql)`. There is no parameter
  binding: every statement is built by string concatenation with
  `sqlLiteral` escaping.
- `src/db/db_client.l` (~4.2k lines): 44 `CREATE TABLE` statements, SQL
  builders and 35+ numbered migrations tracked in `schema_migrations`.
  Several are SQLite-specific: `INSERT OR IGNORE/REPLACE`, `datetime()`,
  `CAST(COUNT(*) AS TEXT)`, and an FTS5 virtual table (`messages_fts`) for
  phase 9 message search.
- `src/db/repository.l` (~4.7k lines, ~206 driver calls) and
  `src/ledger/store.l` (~51 calls); 26 packages import `CloudAgents.Sqlite`.
- Identity: `user_id` is a string, `gh-<github id>` for OAuth users or
  `default` (`CloudAgents.Auth.operatorUserId`) for token/open mode. There
  is no users table, no tenant concept, and isolation is a `WHERE user_id =`
  clause in each query.
- Some lookups happen before the caller's identity is known: MCP callback
  requests resolve a session's `callback_token_hash` from the session id in
  the path; the GitHub token cache resolves `token_hash -> user_id`.

## 3. Dependencies and toolchain

- `Lyric.Db` from NuGet (`0.7.4` at time of writing, same release line as
  the pinned `Lyric.Web`/`Lyric.Docker`) plus `Npgsql`. Connection via
  `Db.connectFromEnv()` (`LYRIC_CONFIG_DB_CONNECTION_URL`, pool size
  `LYRIC_CONFIG_DB_CONNECTION_POOLSIZE`).
- **Parameter typing constraint.** `Lyric.Db` binds every parameter as a
  string (`slice[String]`, synthetic names `@p0`, `@p1`, ...; positional
  `$1` does not bind, per Testamur's recorded trap). Comparing or inserting
  into a non-text column therefore needs an explicit cast in the SQL text
  (`WHERE id = @p0::bigint`, `VALUES (@p1::timestamptz)`). Phase 11 adopts
  explicit casts as the convention and adds a lint-style unit test that
  every SQL builder referencing a typed column casts its parameter. Typed
  parameter binding in `Lyric.Db` itself would remove this; it is filed
  upstream as an improvement, not a blocker.
- All queries become parameterised. `sqlLiteral` string building is removed
  with the SQLite driver; no user-controlled value is ever concatenated into
  SQL text.
- Postgres 17, pinned by image tag.

## 4. Schema

### 4.1 Conventions

- A fresh Postgres migration series, starting with `0001_baseline`, that
  creates the whole current schema in its typed form. The 35+ SQLite
  migrations are not replayed; they stay frozen in history until the
  SQLite code is deleted.
- Types: `bigint` for counts, sizes and sequence numbers; `timestamptz` for
  every timestamp (today epoch-millisecond text; no column stores RFC 3339),
  with the SQLite store's `''`/`'0'` "unset" sentinels becoming NULL; `boolean` for today's `'0'`/`'1'`
  flags; `text` for all stored JSON (every JSON column is either compared or
  hashed byte for byte, or passed through verbatim, and none is queried by
  path, so `jsonb` would add normalisation risk for no benefit), including
  JSON whose exact bytes matter: `session_events.payload` stays `text`
  because the capture hash chain is computed over the verbatim bytes and
  `jsonb` would normalise them, and the same applies to the
  `graph_ingest_outbox` request body; `text` for ids and free text. Enumerated status strings stay
  `text` with a `CHECK` constraint.
- Every tenant-owned table: `tenant_id text NOT NULL DEFAULT
  NULLIF(current_setting('app.current_tenant', true), '') CHECK (tenant_id
  <> '')` as the leading column of its primary key, `ENABLE` + `FORCE ROW
  LEVEL SECURITY`, and one policy `USING (tenant_id =
  NULLIF(current_setting('app.current_tenant', true), '')) WITH CHECK
  (same)`. The `NULLIF` matters: once a pooled connection has used
  `set_config`, an unset setting reads back as `''` rather than NULL, and
  without it the DEFAULT would write `''`-tenant rows that the policy then
  accepts. With it, an unscoped query fails closed: reads return no rows
  (NULL never equals anything) and inserts fail the `NOT NULL`/`CHECK`
  constraints. The same `NULLIF` form is used for `app.current_user` in
  §4.3a.
- Foreign keys include `tenant_id`, so a row can never reference another
  tenant's row. The baseline adds none between tenant-owned tables: the
  SQLite store has none and its delete paths rely on application ordering,
  so each domain's port (slice C) adds its foreign keys once that ordering is
  verified. A stray cross-tenant id cannot be read through in the meantime,
  because both rows are under RLS.
- `0001_baseline` was edited in place until deployments started applying
  it (before slice E); it is now frozen, and every change is a new migration
  (`0002_cutover`, slice E).

### 4.2 Global (non-tenant) tables

These are read before a tenant is known, so they are not under RLS. Each
holds the minimum needed to resolve identity or route a request.

| Table | Purpose |
|---|---|
| `users` | `id` (today's `gh-<id>` / `default` string kept as the key), `github_id`, `github_login`, `created_at` |
| `tenants` | `id`, `name`, `kind` (`personal`, `github_org`, `native`), `github_org_id` (nullable, unique), `created_at` |
| `memberships` | `(tenant_id, user_id)` PK, `role` (`owner`, `admin`, `member`), `source` (`github`, `native`), `created_at`, `synced_at` |
| `invitations` | `id`, `tenant_id`, `token_hash`, invitee `github_login`, `role`, `expires_at`, `accepted_at`, `created_by` |
| `session_routes` | `session_id` PK, `tenant_id`, `user_id` (the session's owner), `callback_token_hash`: the callback path's pre-tenant lookup (moved out of `sessions`), from which the resolver builds the full `TenantScope` |
| `github_token_cache` | unchanged purpose: `token_hash -> user_id` |
| `schema_migrations` | migration ledger |

The application role gets only the privileges each of these needs
(`SELECT` on routing tables, narrow `INSERT/UPDATE` where required); none of
them holds session content.

### 4.3 Tenant-owned tables

Every other current table (sessions, messages, runs, profiles and their
join tables, prompts, ledger tables, scheduled jobs, webhooks,
session events, graph-ingest outbox, attachments and artifacts metadata,
and the rest listed in `db_client.l`) gains `tenant_id` and RLS per §4.1.
Rows that are also per-user keep their `user_id` column.

### 4.3a User-owned tables

Some data belongs to a person, not to an organisation, and must follow the
user whichever organisation is active. It must also be readable at sign-in
and by membership sync, before any tenant is chosen:

| Table | Holds |
|---|---|
| `credentials` | the user's encrypted vault entries, including the `GITHUB_TOKEN` that the OAuth callback vaults today |
| `github_oauth_refresh` | the user's refresh-token metadata (expiring-token OAuth apps only) |
| `user_sync_state` | `user_id` PK, `github_synced_at`, `claimed_until`: membership-sync bookkeeping (§6.2) |

These tables have no `tenant_id`. They are keyed by `user_id` with forced
RLS and a policy `USING (user_id = NULLIF(current_setting('app.current_user',
true), '')) WITH CHECK (same)`, so a unit of work sees only the calling
user's rows whatever tenant is active. A unit that needs only user-owned
data (sign-in, membership sync) sets `app.current_user` alone, via a
`UserScope` that the store layer rejects when empty, exactly as for
`TenantScope` (§5.2). Harness credentials used by a run are the run
creator's own. A tenant-owned `profile_credentials` row may reference only
the profile creator's own credential ids; this is checked on write.
`user_sync_state` is also claimable (§5.3): besides its per-user policy it
has the two claimer policies (`FOR SELECT` and `FOR UPDATE TO
cloudagents_claimer USING (true)`). Postgres combines permissive policies
with OR per role, and the per-user policy never matches for the claimer
role (it has no `app.current_user`), so the claimer sees every row while
the service role still sees only the calling user's row.

### 4.4 Message search

The FTS5 table is replaced by a generated `tsvector` column on `messages`
with a GIN index, queried with `plainto_tsquery` rewritten to prefix
lexemes (every word a case-insensitive prefix, operators inert; see
docs/phase9-message-search.md §8). `websearch_to_tsquery` was rejected
because it interprets `OR`, `-` and quotes as operators, which the FTS5
builder deliberately neutralises. The FTS5 builder moved beside its SQL in
`CloudAgents.Db`, and both stores take the user's raw term. Any behaviour difference
from FTS5 (prefix matching, phrase handling, ranking) is either matched or
listed in the PR and in `docs/phase9-message-search.md`.

## 5. Tenancy at runtime

### 5.1 Roles

- `cloudagents_owner`: owns all objects; used only by the migration step
  (`--migrate`, separate DSN `CLOUD_AGENTS_MIGRATE_DATABASE_URL`).
- `cloudagents_claimer`: `NOLOGIN`; owns only the claim functions (§5.3).
- `cloudagents_app`: the service role. Not owner, not superuser, no
  `BYPASSRLS`. The service refuses to start if it detects it is connected
  as an owner, superuser or `BYPASSRLS` role, because `FORCE ROW LEVEL
  SECURITY` would then be vacuous.

### 5.2 Request scoping

- Auth middleware resolves the user (unchanged token/OAuth logic) and the
  active organisation from the `X-CloudAgents-Org` header, defaulting to
  the user's personal organisation. The organisation is accepted only if a
  `memberships` row exists for that user and is not suspended; otherwise
  `403`. The middleware stamps the validated tenant with the user for the
  request thread, and `CloudAgents.Auth.requestScope()`, read once at handler
  entry, returns it (slice F1).
- **Explicit scope, never ambient.** The middleware produces a
  `TenantScope` value (`tenantId`, `userId`), and it is passed as an explicit
  parameter to every repository and ledger-store function that touches
  tenant-owned data. It is not stored in, or read from, the thread-local
  slot that `CloudAgents.Auth.currentUserId` uses today. That slot is lost
  or wrong once an `await` resumes on another thread (async handlers, the
  SSE poll loop, `docker_manager.l`'s async paths), and it falls back to the
  operator identity when unset. Both properties would defeat the fail-closed
  guarantee.
- **No default tenant.** `TenantScope` has no default and no fallback. It is
  constructed in exactly three places: the auth middleware (from a validated
  membership), the callback-token resolver (from `session_routes`), and the
  maintenance claim functions (§5.3, per claimed item). Token/open mode resolves the `default` user's personal tenant
  explicitly in the middleware, not as a fallback. A scope with an empty
  tenant or user id is rejected by the store layer with an error before any
  SQL runs.
- Handler call sites change to pass the scope through. This happens once,
  in slice B (§9), against the existing SQLite-backed repository, so the
  thread-slot dependency is removed before any Postgres code is live.
- **Per unit of work.** Each repository operation (or explicit
  multi-statement unit) runs on one pooled connection inside a
  `Lyric.Db` transaction (`conn.transaction()`, then `tx.execute`/`tx.query`,
  then `commit`): `SELECT set_config('app.current_tenant', @p0, true),
  set_config('app.current_user', @p1, true)`, the operation's statements,
  then COMMIT. This is the pattern Testamur's `Server.Tenant` already runs
  against live Postgres. Transaction-local settings cannot leak to the next
  borrower of a pooled connection, and long-lived handlers (the SSE output
  stream and its poll loop) never hold a transaction open between ticks.
- **Cost.** Each unit adds the `set_config` statement to its transaction (one
  extra statement, same connection, no extra connection checkout). Hot
  paths with several reads (e.g. a session page load) group them into one
  unit rather than paying it per query.

### 5.3 Cross-tenant background work

Maintenance endpoints (`trigger-jobs`, `drain-graph-ingest`, `observe`,
`ledger-sync`, `reap`) must find due work across all tenants. This is done
without a login role that bypasses RLS: a small set of `SECURITY DEFINER`
claim functions each return `(tenant_id, id)` pairs for due items using
`FOR UPDATE SKIP LOCKED`.

The functions cannot be owned by `cloudagents_owner`: `FORCE ROW LEVEL
SECURITY` applies to the table owner too, so a function running as the
owner would see no rows. Instead they are owned by `cloudagents_claimer`, a
`NOLOGIN` role that can only be reached through these functions. It has no
`BYPASSRLS`; each claimable table (`scheduled_jobs`,
`graph_ingest_outbox`, the observer and ledger-sync queues, `runs`, and the
user-owned `user_sync_state` of §4.3a) gets
two extra policies, `FOR SELECT TO cloudagents_claimer USING (true)` and
`FOR UPDATE TO cloudagents_claimer USING (true)` (both are needed for
`SELECT ... FOR UPDATE`), plus only the column privileges the claim needs. Every other table stays
invisible to it.

`SKIP LOCKED` alone does not prevent a double claim: the row lock is released
when the claim function's transaction commits, before the caller has done
the work. So each claimable table carries `claimed_until timestamptz`, and a
claim function selects only due items whose `claimed_until` is NULL or in
the past (`FOR UPDATE SKIP LOCKED`). It sets `claimed_until = now() +
lease` on them in the same statement before returning. The tenant-scoped
worker clears `claimed_until` (and records the outcome) when it finishes. An
item whose worker dies becomes claimable again once its lease expires.
Workers are written to be idempotent, as today's outbox and job handlers
already are, because a lease can expire under a very slow worker. All subsequent work on a claimed item
runs tenant-scoped as in §5.2. The claim functions are the only
cross-tenant read path and are reviewed as such. Each one:

- is declared with `SET search_path = pg_catalog, pg_temp` and uses
  schema-qualified table names, so a caller cannot redirect it through an
  object on its own search path;
- has `EXECUTE` revoked from `PUBLIC` and granted to `cloudagents_app` only;
- returns only the keys needed to build the worker's scope and a bounded
  number of rows (a `limit` argument with a hard maximum), never row
  content: `(tenant_id, id, user_id)` for tenant-owned tables, where
  `user_id` is the row's owner and completes the worker's `TenantScope`,
  `(user_id)` for `user_sync_state`, whose worker runs under a `UserScope`
  (§4.3a);
- takes no argument that is interpolated into SQL.

One function is not a claim: `prune_graph_ingest_outbox(p_retention_days)`
deletes delivered outbox rows older than the retention window (at least one
day) in every tenant, so the outbox stays bounded without a per-tenant sweep.
It is hardened the same way, and `cloudagents_claimer` holds `DELETE` on the
outbox through a policy that admits delivered rows only, so it cannot remove
a pending row whatever its argument.

### 5.3a Several API instances

Owner decision (§11, resolved question 3): phase 11 supports several API
instances behind a load balancer before ADR-008's runner agent exists. Every
piece of background work that assumed a single instance is made safe for
concurrent callers on any instance:

- **Scheduled jobs** are claimed by advancing their schedule rather than by a
  lease, because a run can take up to 30 minutes. `claim_scheduled_jobs`
  stamps `last_run_at` with the firing time and moves `next_run_at` to the
  first slot on the job's cadence after it, in the statement that selects
  the job (`FOR UPDATE SKIP LOCKED`); a one-shot job becomes `completed`. No
  other caller can fire the same slot, and nothing is recorded after the
  run. A run cut short by an instance crash is not re-fired, which follows
  ADR-008 §4: a run that may have had side effects is never silently
  retried. A skipped run (its session was busy) releases the claim, guarded
  on the row still holding what the claim wrote. The SQLite store uses the
  same semantics (a conditional UPDATE per job), so the cut-over changes
  nothing for jobs.
- **Leased queues**: the graph-ingest outbox is claimed through its claim
  function with a 5-minute lease (§5.3); a crashed drain's rows become
  claimable again when it expires.
- **Ledger sync and observer passes** already claim per session, so they
  need no new lease: a sync pass takes the session's sync lease
  (`acquireSyncLease`, 30 minutes, longer than a full budget of GitHub
  calls), and an observer pass is taken by clearing the session's pending
  flag in one conditional update (`claimObserverPass`). What Postgres adds is
  how a sweep finds them across tenants: `list_sessions_to_sync` and
  `list_observer_passes` are read-only listing functions, hardened like the
  claim functions, that return scope keys only; each session is then claimed
  under its route scope. Issue ownership for sync is decided within a
  tenant.
- **Runs.** Until the runner agent owns runs (ADR-008 §2, §4), the instance
  that starts a run drives it. The session row records that instance
  (`run_instance`: `CLOUDAGENTS_INSTANCE_ID`, else the host name) and a
  heartbeat (`run_heartbeat_at`), set when the run is claimed and renewed
  every 30 seconds by the poll loops that drive it (the run, an observer
  pass, an end-of-run inspect container). The heartbeat is on the session
  rather than the `runs` row because an observer pass holds a session
  `RUNNING` without a `runs` row. A `RUNNING` session with no heartbeat for
  2 minutes (or none at all, e.g. left by an older version) is stranded:
  the maintenance sweep (`POST /api/maintenance/reap`) takes it over by a
  compare-and-set that hands the run to `sweep:<instance>` and renews its
  heartbeat (`claim_stranded_runs` on Postgres, which also returns the
  instance that went quiet, for the log), stops its container, marks its
  running `runs` rows failed with the usual failed-run webhook, and returns
  the session to `IDLE`. A container that cannot be stopped (one already
  gone counts as stopped) leaves the session held by the sweep, and a later sweep retries once its renewed
  heartbeat goes stale. A late heartbeat from the original instance
  changes nothing once the run is taken over. Instance startup no longer
  resets every `RUNNING` or `WARM` session, which would kill runs another
  instance is driving.
- **Warm containers** can be reaped by any instance. On Postgres each is
  claimed with a lease (`claim_warm_sessions`); on both stores the session
  is freed before its container is stopped, only while it is still `WARM`
  on that container, so a run that started on it since keeps its container
  and two reapers never both stop it.

| Setting | Default |
|---|---|
| Run heartbeat interval | 30 s |
| A run is stranded after | 2 min without a heartbeat |
| Lease on outbox and warm-reaper items | 5 min |
| Ledger-sync lease per session (existing) | 30 min |
| A scheduled run interrupted mid-run | marked failed, not re-run |

### 5.4 Visibility rule

Within an organisation, list and read endpoints keep today's filter: a user
sees the sessions, prompts, profiles and jobs they own. Organisation
admins get no extra read access in this phase. This preserves current
behaviour exactly for existing users (each in a personal organisation) and
defers sharing semantics.

## 6. Organisation membership

### 6.1 Personal organisations

Every user has exactly one `personal` tenant, id `personal:<user id>`,
created on first sign-in, with the
user as `owner`. Token/open
mode maps to the `default` user's personal tenant.

### 6.2 GitHub-synced organisations

- The OAuth scope becomes `repo read:user read:org` (`frontend/src/lib/auth.ts` and
  its test). Existing users see one re-consent prompt.
- A GitHub organisation becomes a tenant only when a user who is an admin
  of that GitHub organisation connects it (explicit action; cloud-agents
  does not auto-create a tenant for every organisation a user belongs to).
  The connecting user becomes `owner`.
- At each sign-in, the user's GitHub organisation memberships are fetched
  (`GET /user/memberships/orgs`, which includes role) and reconciled
  against `memberships` rows with `source = 'github'` for connected
  organisations: added, role-updated, or removed. GitHub `admin` maps to
  `admin`, otherwise `member`; the tenant's `owner` is never downgraded by
  sync.
- Sync never touches `source = 'native'` rows. A user who has both keeps
  the native row.
- A sync failure (GitHub unavailable) keeps existing rows and logs; it does
  not lock the user out of their personal organisation.
- Sign-in alone would leave a removed member with access for as long as
  their browser session lasts. So GitHub-sourced memberships are also
  re-verified by a `POST /api/maintenance/membership-sync` endpoint (same
  operator-polled idiom and claim/lease mechanism as §5.3). A claim function
  over `user_sync_state` returns users whose `github_synced_at` is over an
  hour old and who hold at least one `github` membership. For each claimed
  user the worker runs under that user's `UserScope`, reads their vaulted
  `GITHUB_TOKEN` (§4.3a), and reconciles `memberships`. A membership
  GitHub no longer reports is removed. If the user's token has been revoked
  or lacks `read:org`, their GitHub-sourced memberships are suspended (not
  deleted) until they sign in again. The revocation window is therefore
  bounded by the sync interval (one hour by default), and this is stated in
  the organisation settings UI. Immediate revocation via GitHub
  organisation webhooks needs a GitHub App installation and is deferred.

### 6.3 Native organisations and invitations

- Any user can create a `native` organisation and becomes its `owner`.
- Owners and admins invite by GitHub login. The invitation carries a
  single-use token (stored hashed), a role and an expiry; accepting it
  requires signing in as that GitHub login.
- Owners can change roles and remove members; the last owner cannot be
  removed or demoted.

### 6.4 API and UI

New endpoints under `/api/orgs` (list mine, create, connect GitHub org,
members, invitations, accept). The frontend gains an organisation switcher
(hidden when the user has only a personal organisation) and an
organisation settings page. `CLOUD_AGENTS_WHITELIST` keeps gating who may
sign in at all; organisation membership gates what they can access.

## 7. SQLite export (dropped)

Dropped (owner, 2026-10-01): production holds no data worth keeping, so the
cut-over (slice E) starts the service on an empty, freshly migrated
database instead of exporting SQLite. Slice D is not built.

The role `cloudagents_migrator` stays, unused: the frozen baseline grants to
it, so it must exist. `provision.sql` now creates it `NOLOGIN NOBYPASSRLS`
(an earlier install keeps `BYPASSRLS` until a superuser runs `ALTER ROLE
cloudagents_migrator NOBYPASSRLS`), migration `0002_cutover` revokes its
table grants, and the startup self-check still refuses to serve while it can
log in.

## 8. Deployment

- Roles and grants are created by one checked-in script,
  `deploy/postgres/provision.sql`, run once as the Postgres superuser with
  `psql` variables for the role passwords. It creates the database and the
  four roles (§5.1), the migrator as `NOLOGIN`, and grants
  `cloudagents_owner` what it needs to run migrations. Grants to the other
  roles and the per-table policies are created by the migrations themselves
  (as `cloudagents_owner`), so they stay versioned with the schema.
  `CREATEROLE` and `BYPASSRLS` need a superuser, which is why this step is
  separate from `--migrate`.
- Both compose files (`deploy/docker-compose.yml`, and
  `deploy/docker-compose.coolify.yml` for Coolify) run Postgres as a
  service of the app's stack (owner, 2026-10-01; this replaces a separate
  Coolify database resource):
  - `postgres`: `deploy/postgres.Dockerfile` (pinned `postgres` image),
    named volume `pg_data`, healthcheck over TCP (so it passes only after
    first-start provisioning), 1 GB memory limit, no published port. On
    first start `deploy/postgres/init.sh` runs `provision.sql` with the
    owner and app passwords from the environment
    (`CLOUD_AGENTS_PG_OWNER_PASSWORD`, `CLOUD_AGENTS_PG_APP_PASSWORD`,
    letters and digits only) and a random migrator password. The
    superuser password (`CLOUD_AGENTS_PG_SUPERUSER_PASSWORD`) stays inside
    that container.
  - `migrate`: a one-shot run of the API image with `--migrate` and the
    owner DSN, after `postgres` is healthy. The owner's credentials reach
    only this container.
  - `api`: starts after `migrate` succeeds, with only the service DSN
    (`LYRIC_CONFIG_DB_CONNECTION_URL`, as `cloudagents_app`); the startup
    self-check runs on every start, and the service refuses to start without
    the DSN.
  - `maintenance`: the poller for the operator-only maintenance endpoints
    (`deploy/maintenance.sh`, one loop per endpoint, intervals from
    `MAINTENANCE_*_SECONDS`), authenticating with
    `CLOUD_AGENTS_API_TOKEN`, which both compose files now require. It is
    what runs the §5.3a sweeps on a schedule.
- The startup self-check (§5.1) also verifies that the expected roles
  exist and that the service role has its grants. If not, it exits with a
  message naming the missing role or grant and pointing at `provision.sql`,
  rather than failing on the first query.
- Managed-provider note for ADR-008 phase 4: some managed Postgres
  offerings do not grant `BYPASSRLS`. Nothing needs it now that the export
  is dropped (§7).
- Backups: Coolify's scheduled database backups cover database resources,
  not compose services, so `backup.sh` takes a `pg_dump` (custom format,
  checked with `pg_restore --list`) from the running `postgres` container
  on both deployments.
- Only standard Postgres features are used, and the service connects via
  DSN environment variables, so moving to managed Postgres at ADR-008
  phase 4 is dump, restore and a DSN change.

## 9. Delivery slices

Each slice is its own PR, green and deployable. Production stayed on SQLite
until slice E; slice D is dropped (§7). Organisations (slice F) come after cut-over, because
memberships, invitations and organisation switching need tables that exist
only in Postgres; nothing that production runs before cut-over depends on
Postgres-only data.

- **A. Foundations.** Shipped: `Lyric.Db` + `Npgsql` dependencies,
  `CloudAgents.Pg` (scopes, units of work), the migration runner and
  `--migrate`, `provision.sql`, the typed baseline schema with global,
  user-owned and tenant-owned tables and their RLS, roles, the claim-function
  mechanism with the two claim functions whose Postgres form is new
  (`claim_graph_ingest_outbox`, `claim_membership_sync`), the startup
  self-check, a CI Postgres service, and the live suite
  (`tests/pg_live_tests.l`). The unit-of-work go/no-go test passed. The
  other queues (`scheduled_jobs`, the observer, ledger sync) each have their
  own claim semantics; their claim functions are written with their domain's
  port in slice C and tested together with it (§5.3a). Not wired into request handling.
- **B+C. Scope plumbing and store port, one domain per PR.** Slices B and
  C are done together, domain by domain (prompts; profiles and library;
  sessions and messages; interactive requests; jobs, webhooks and
  maintenance; ledger; capture and outbox; search), rather than as two
  passes over the same ~270 store functions and their call sites. Each
  domain PR:
  - adds `TenantScope`/`UserScope` (§5.2, §4.3a) to that domain's
    SQLite-backed repository functions in place of the `userId` argument,
    same position, so production behaviour is unchanged (the SQLite code uses
    `sc.userId`);
  - switches the domain's handlers to `CloudAgents.Auth.requestScope()`,
    read once at handler entry before any `await`, and passes the value
    down explicitly;
  - adds `CloudAgents.PgStore.<Domain>`, the Postgres implementation with the
    same signatures (including the `DbError` type) and semantics, plus live
    Postgres tests; handlers keep calling the SQLite repository, so
    production is unaffected.
  With no organisations yet, every scope is the user's implicit personal
  tenant, `personal:<user id>` (`CloudAgents.Pg.personalScope`). Postgres
  store conventions: text ordering uses `COLLATE "C"` to match SQLite's
  BINARY collation; epoch-millisecond strings convert to and from
  `timestamptz` with exact integer interval arithmetic
  (`CloudAgents.Pg.msIn`/`msOut`), never `to_timestamp(float)`.
- **D. Export tool.** Dropped (§7): the cut-over starts on an empty
  database.
- **E. Cut-over.** Shipped as one PR:
  - `CloudAgents.Repository`, `CloudAgents.SessionStore` and
    `CloudAgents.Ledger.Store` keep their signatures and delegate every store
    function to `CloudAgents.PgStore.*` (handlers unchanged apart from the
    two fixes below). The facades' SQLite bodies are gone.
  - Personal tenants (§6.1) are provisioned on a user's first authenticated
    request (`CloudAgents.PgStore.Tenancy.ensurePersonalTenant`, cached per
    process): the `users` row, the tenant and the owner membership.
  - The service refuses to start without `LYRIC_CONFIG_DB_CONNECTION_URL`;
    the SQLite schema runner and the legacy `CLOUD_AGENTS_SESSIONS_JSON`
    import are removed.
  - `CloudAgents.Sqlite`, the SQLite SQL builders and the SQLite NuGet
    packages and native runtimes are deleted; the store error type moved to
    `CloudAgents.Db.DbError`.
  - Migration `0002_cutover`: the ledger policy cache may record
    `unavailable` (as the SQLite store did), and the export role loses its
    grants (§7).
  - Fixes found in the switch: the agent-messages read for highlights now
    takes the request's scope; the duplicate-profile-name race is detected
    from Postgres's 23505 on the profiles name constraint; two ledger store
    bugs (an `unavailable` policy status, a non-numeric sync-lease token).
  - The test suites run against live Postgres, each test as a fresh user
    with its own personal tenant, so suites and repeated runs never see each
    other's rows.
- **F. Organisations** (§6.2 to §6.4), on Postgres, in three PRs:
  - **F1.** `X-CloudAgents-Org` resolution against `memberships`; native
    organisations and invitations; `/api/orgs` (§6.3, §6.4). Global tables
    have no RLS, so `CloudAgents.PgStore.Orgs` authorises every call against
    the caller's own membership row, and locks the tenant row before any
    change that could remove its last owner. Invitations are matched against
    the login recorded at sign-in (case-insensitively), last 7 days, and a
    newer invitation for the same login replaces a pending one. The
    invitation link is returned once to the inviter, who shares it; there is
    no email.
  - **F2.** GitHub organisations (§6.2): the `read:org` scope, connecting an
    organisation, sync at sign-in and the hourly membership sync.
  - **F3.** The frontend switcher and settings page (§6.4). The OAuth scope
    change ships here with the UI that needs it.

## 10. Acceptance criteria

- With two tenants populated, every live suite passes under
  `cloudagents_app`, and a cross-tenant read (session, message, credential,
  ledger entry, event) by id returns nothing and a cross-tenant write is
  rejected.
- A query issued without a tenant scope returns no rows.
- The service refuses to start under an owner, superuser or `BYPASSRLS`
  role.
- A store call with an empty `TenantScope` fails with an error before
  issuing SQL, and a store call made from an async continuation (after an
  `await` that may resume on another thread) uses exactly the scope it was
  passed.
- Each claim function has `EXECUTE` revoked from `PUBLIC`, a fixed
  `search_path`, and returns only its scope keys (§5.3) (checked by a live test
  that queries `pg_proc` and calls it as a role without the grant).
- With two tenants' due items present, a claim function called with no
  tenant scope returns both tenants' items; `cloudagents_claimer` cannot
  log in, and cannot read any non-claimable table.
- On a pooled connection that has previously run a scoped unit, an
  unscoped insert into a tenant-owned table is rejected, and no row with an
  empty `tenant_id` can exist.
- Two concurrent callers of the same claim function never receive the same
  item while its lease is live, and an item whose lease has expired is
  claimable again.
- The service refuses to start while `cloudagents_migrator` can log in
  (§7).
- Removing a member from a connected GitHub organisation removes their
  cloud-agents membership within one sync interval without a sign-in.
- A user's credentials are visible to them whichever organisation is
  active, invisible to every other user including admins of a shared
  organisation, and readable at sign-in before a tenant is chosen.
- A profile cannot reference another user's credential.
- After the cut-over, every session's MCP callback authenticates via
  `session_routes`.
- On a database without `provision.sql` applied, the service exits with an
  error naming the missing role.
- GitHub sync adds, updates and removes `github`-sourced memberships and
  never changes `native` ones or demotes an owner.
- After slice E, no SQLite code or package remains, and `grep -r sqlLiteral
  src` is empty.

## 11. Resolved questions (owner, 2026-09-29)

1. Visibility within an organisation stays creator-only (§5.4) for this
   phase. Organisation admins get no extra read access; sharing and audit
   views are a later product decision.
2. Search differences between FTS5 and Postgres `tsvector` search (§4.4)
   are documented rather than matched exactly, in the search-slice PR and in
   `docs/phase9-message-search.md`.
3. Several API instances are supported in this phase (§5.3a), using leases
   and heartbeats, with the defaults in §5.3a's table: a 30-second run
   heartbeat, a run stranded after 2 minutes without one, 5-minute leases,
   and a scheduled run interrupted by an instance crash marked failed rather
   than re-run (owner, 2026-09-30).
4. No SQLite export (owner, 2026-10-01): production holds no data worth
   keeping, so slice D is dropped and the cut-over starts on an empty
   database (§7). Postgres runs as a service in the app's compose stack on
   both the standalone and the Coolify deployment, backed up by
   `backup.sh`'s `pg_dump`, rather than as a separate Coolify database
   resource (§8).
