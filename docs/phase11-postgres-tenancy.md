# Phase 11: Postgres and organisation tenancy (ADR-008 phase 1)

Status: spec, awaiting review. No implementation yet.

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
- A one-shot, verified export of an existing SQLite database into Postgres.
- Live-Postgres test suites in CI, including a two-tenant isolation proof.
- SQLite driver and SQLite-specific SQL deleted once production has been
  migrated (ADR-008: no second backend kept).

Non-goals (later phases or explicitly deferred):

- Multi-instance API, runner hosts, object storage (ADR-008 phases 2 to 4).
- Organisation-wide session sharing. Phase 11 keeps today's visibility rule:
  a user sees only the sessions they created, now also scoped to the active
  organisation (§5.4). Sharing is a later product decision.
- Managed Postgres. Phase 11 targets a Coolify-hosted Postgres instance on
  the existing VM; the move to managed Postgres happens at ADR-008 phase 4
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
  every timestamp (today RFC 3339 text); `boolean` for today's `'0'`/`'1'`
  flags; `jsonb` for stored JSON payloads (e.g. `session_events.payload`
  keeps its verbatim bytes as `text` where the hash chain covers the exact
  bytes); `text` for ids and free text. Enumerated status strings stay
  `text` with a `CHECK` constraint.
- Every tenant-owned table: `tenant_id text NOT NULL DEFAULT
  current_setting('app.current_tenant', true)` as the leading column of its
  primary key, `ENABLE` + `FORCE ROW LEVEL SECURITY`, and one policy
  `USING (tenant_id = current_setting('app.current_tenant', true))
  WITH CHECK (same)`. An unset tenant setting matches nothing, so an
  unscoped query fails closed (returns no rows, inserts are rejected).
- Foreign keys include `tenant_id`, so a row can never reference another
  tenant's row.

### 4.2 Global (non-tenant) tables

These are read before a tenant is known, so they are not under RLS. Each
holds the minimum needed to resolve identity or route a request.

| Table | Purpose |
|---|---|
| `users` | `id` (today's `gh-<id>` / `default` string kept as the key), `github_id`, `github_login`, `created_at` |
| `tenants` | `id`, `name`, `kind` (`personal`, `github_org`, `native`), `github_org_id` (nullable, unique), `created_at` |
| `memberships` | `(tenant_id, user_id)` PK, `role` (`owner`, `admin`, `member`), `source` (`github`, `native`), `created_at`, `synced_at` |
| `invitations` | `id`, `tenant_id`, `token_hash`, invitee `github_login`, `role`, `expires_at`, `accepted_at`, `created_by` |
| `session_routes` | `session_id` PK, `tenant_id`, `callback_token_hash`: the callback path's pre-tenant lookup (moved out of `sessions`) |
| `github_token_cache` | unchanged purpose: `token_hash -> user_id` |
| `schema_migrations` | migration ledger |

The application role gets only the privileges each of these needs
(`SELECT` on routing tables, narrow `INSERT/UPDATE` where required); none of
them holds session content.

### 4.3 Tenant-owned tables

Every other current table (sessions, messages, runs, profiles and their
join tables, prompts, credentials, ledger tables, scheduled jobs, webhooks,
session events, graph-ingest outbox, attachments and artifacts metadata,
and the rest listed in `db_client.l`) gains `tenant_id` and RLS per §4.1.
Rows that are also per-user keep their `user_id` column. User-scoped
secrets (`credentials`, `github_oauth_refresh`) additionally have an RLS
policy clause restricting reads to `user_id =
current_setting('app.current_user', true)`, so they stay private to their
owner inside a shared organisation (ADR-008 decision 10, ADR-006).

### 4.4 Message search

The FTS5 table is replaced by a generated `tsvector` column on `messages`
with a GIN index, queried with `websearch_to_tsquery`. The current query
builder in `src/handlers/search.l` (quote-injection handling, term
semantics) is rewritten against the new syntax. Any behaviour difference
from FTS5 (prefix matching, phrase handling, ranking) is either matched or
listed in the PR and in `docs/phase9-message-search.md`.

## 5. Tenancy at runtime

### 5.1 Roles

- `cloudagents_owner`: owns all objects; used only by the migration step
  (`--migrate`, separate DSN `CLOUD_AGENTS_MIGRATE_DATABASE_URL`).
- `cloudagents_app`: the service role. Not owner, not superuser, no
  `BYPASSRLS`. The service refuses to start if it detects it is connected
  as an owner, superuser or `BYPASSRLS` role, because `FORCE ROW LEVEL
  SECURITY` would then be vacuous.

### 5.2 Request scoping

- Auth middleware resolves the user (unchanged token/OAuth logic) and the
  active organisation from the `X-CloudAgents-Org` header, defaulting to
  the user's personal organisation. The organisation is accepted only if a
  `memberships` row exists for that user; otherwise `403`.
- Scoping is per unit of work, not per request: each repository operation
  (or explicit multi-statement unit) runs as `BEGIN; SELECT
  set_config('app.current_tenant', @p0, true); SELECT
  set_config('app.current_user', @p1, true); ...; COMMIT` on one pooled
  connection. Transaction-local settings cannot leak to the next borrower
  of a pooled connection. Long-lived handlers (the SSE output stream and
  its poll loop) therefore never hold a transaction open between ticks.
- Tenant and user are read from the thread-scoped request context
  (extending today's `CloudAgents.Auth.currentUserId` slot); repository
  function signatures stay unchanged, so handler code does not change in
  this phase.

### 5.3 Cross-tenant background work

Maintenance endpoints (`trigger-jobs`, `drain-graph-ingest`, `observe`,
`ledger-sync`, `reap`) must find due work across all tenants. This is done
without a bypass role: a small set of `SECURITY DEFINER` claim functions,
owned by `cloudagents_owner`, each return `(tenant_id, id)` pairs for due
items using `FOR UPDATE SKIP LOCKED`. All subsequent work on a claimed item
runs tenant-scoped as in §5.2. The claim functions are the only
cross-tenant read path and are reviewed as such.

### 5.4 Visibility rule

Within an organisation, list and read endpoints keep today's filter: a user
sees the sessions, prompts, profiles and jobs they own. Organisation
admins get no extra read access in this phase. This preserves current
behaviour exactly for existing users (each in a personal organisation) and
defers sharing semantics.

## 6. Organisation membership

### 6.1 Personal organisations

Every user has exactly one `personal` tenant, created on first sign-in (or
by the export for existing users), with the user as `owner`. Token/open
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

## 7. SQLite export

A server subcommand, `CloudAgents.dll migrate-from-sqlite --sqlite <path>`,
run once with the API stopped:

1. Refuses to run unless the target database has the baseline schema and
   no tenant-owned rows.
2. Creates a `users` row and a personal tenant for every distinct `user_id`
   in the source.
3. Copies every table in dependency order, converting text to typed
   values. Any value that fails conversion aborts the whole export with the
   table, row key and value; nothing is silently coerced or dropped.
4. Runs in a single transaction; on success prints per-table row counts
   for source and target and exits non-zero if any differ.

The runbook gains the cut-over procedure: stop the API, back up the SQLite
file (`backup.sh`), run migrations, run the export, switch the environment
to the Postgres DSN, start the API, then smoke-test.

## 8. Deployment

- Standalone compose (`deploy/docker-compose.yml`): a `postgres` service
  (pinned image, named volume, healthcheck, memory limit), with the API
  depending on it. Role and database creation via an init script.
- Coolify: a separate Coolify Postgres resource (not in the compose file),
  with the two DSNs set in the API's environment. Coolify's scheduled
  database backups to S3-compatible storage are configured at least hourly;
  `COOLIFY.md` documents it.
- `backup.sh` gains a `pg_dump` path for the standalone deployment.
- Only standard Postgres features are used, and the service connects via
  DSN environment variables, so moving to managed Postgres at ADR-008
  phase 4 is dump, restore and a DSN change.

## 9. Delivery slices

Each slice is its own PR, green and deployable. Production stays on SQLite
until slice F.

- **A. Foundations.** `Lyric.Db` + `Npgsql` dependencies, Postgres
  connection, migration runner and `--migrate`, baseline schema with
  global tables, RLS and roles, role self-check at startup, CI Postgres
  service, and the two-tenant isolation live suite. Not wired into request
  handling yet.
- **B. Tenancy core.** Request scoping (§5.2), personal organisations,
  `X-CloudAgents-Org` resolution, `SECURITY DEFINER` claim functions.
- **C. Store port.** Port the repository and ledger store to parameterised
  Postgres queries, one domain per PR (sessions and messages; profiles and
  library; jobs, webhooks and maintenance; ledger; capture and outbox;
  search). Behind the unchanged repository API; each ported domain has live
  Postgres tests. While slices are in flight the service still runs on
  SQLite in production; ported code is exercised by CI only.
- **D. Organisations.** GitHub sync with `read:org`, native organisations,
  invitations, `/api/orgs`, frontend switcher and settings.
- **E. Export tool** (§7) with a test that exports a fixture SQLite database
  containing every table and verifies counts and typed values.
- **F. Cut-over.** Runbook and compose changes, production migration, then
  deletion of `CloudAgents.Sqlite`, the SQLite SQL builders and the SQLite
  NuGet packages in the same PR.

## 10. Acceptance criteria

- With two tenants populated, every live suite passes under
  `cloudagents_app`, and a cross-tenant read (session, message, credential,
  ledger entry, event) by id returns nothing and a cross-tenant write is
  rejected.
- A query issued without a tenant scope returns no rows.
- The service refuses to start under an owner, superuser or `BYPASSRLS`
  role.
- The export of a fixture database reproduces every row with matching
  counts and typed values, and aborts with a precise error on a malformed
  value.
- GitHub sync adds, updates and removes `github`-sourced memberships and
  never changes `native` ones or demotes an owner.
- After slice F, no SQLite code or package remains, and `grep -r sqlLiteral
  src` is empty.

## 11. Open questions

1. Should organisation admins be able to see all sessions in their
   organisation (audit use) in this phase, or is creator-only visibility
   (§5.4) enough until sharing is designed?
2. FTS5 to `tsvector` search differences (§4.4): acceptable to document
   rather than match exactly?
