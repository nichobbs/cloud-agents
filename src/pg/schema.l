//! CloudAgents.Pg.Schema — the Postgres schema for the phase 11 store
//! (docs/phase11-postgres-tenancy.md §4, §5.3), as versioned migrations run by
//! `CloudAgents.Pg.Migrate` as `cloudagents_owner`.
//!
//! Three kinds of table (spec §4.2, §4.3, §4.3a):
//! - **Global** (`users`, `tenants`, `memberships`, `invitations`,
//!   `session_routes`, `github_token_cache`): read before a tenant is known,
//!   so not under row-level security. They hold identity and routing only.
//! - **Tenant-owned** (everything that belongs to an organisation): a leading
//!   `tenant_id` column, `FORCE ROW LEVEL SECURITY`, and a policy keyed on
//!   `app.current_tenant`.
//! - **User-owned** (`credentials`, `github_oauth_refresh`,
//!   `model_listing_cache`, `user_sync_state`): keyed by `user_id` with a
//!   policy on `app.current_user`, so they follow the user across
//!   organisations and stay private to them.
//!
//! Every policy and DEFAULT reads its setting through `NULLIF(..., '')`: once
//! a pooled connection has used a custom setting, an unset value reads back
//! as `''` rather than NULL (verified against Postgres 16). Without `NULLIF`
//! an unscoped insert would default `tenant_id` to `''` and the policy would
//! accept it. With it, unscoped reads match nothing and unscoped inserts are
//! rejected (by the policy's WITH CHECK, and by `NOT NULL` if it ever got that
//! far).
//!
//! Types follow what the SQLite store actually writes (every SQLite column is
//! TEXT): epoch-millisecond strings become `timestamptz`, with `''`/`'0'`
//! "unset" sentinels becoming NULL; `'0'`/`'1'` and `'true'`/`'false'` flags
//! become `boolean` (nullable where `''` is a third state); counts, positions
//! and sequence numbers become integers (12-digit zero padding on
//! `messages.seq` is a presentation concern, not stored). JSON stays `text`:
//! each JSON column is either compared or hashed byte for byte (capture
//! payloads, the ingest outbox body, permission rule inputs) or passed through
//! verbatim, and none is queried by path.
//!
//! No foreign keys between tenant-owned tables yet: the SQLite store has none
//! and its delete paths rely on application ordering, so each is added with
//! its domain's port (slice C) once that ordering is verified. A stray
//! cross-tenant id cannot be read through, because both rows are under RLS.
//!
//! `0001_baseline` may be edited in place until the production cut-over
//! (slice E): no production Postgres database exists before then. After
//! cut-over it is frozen and changes go in new migrations.
@runtime_checked
package CloudAgents.Pg.Schema

import Std.Core

pub record PgMigration {
  pub version: String
  pub statements: slice[String]
}

pub func migrations(): slice[PgMigration] {
  return [PgMigration(version = "0001_baseline", statements = baselineStatements())]
}

pub func latestVersion(): String {
  return "0001_baseline"
}

// ─── Fragments ──────────────────────────────────────────────────────────────
func tenantSetting(): String {
  return "NULLIF(current_setting('app.current_tenant', true), '')"
}

func userSetting(): String {
  return "NULLIF(current_setting('app.current_user', true), '')"
}

func tenantCol(): String {
  return "tenant_id text NOT NULL DEFAULT " + tenantSetting() + " CHECK (tenant_id <> ''), "
}

func userOwnerCol(): String {
  return "user_id text NOT NULL DEFAULT " + userSetting() + " CHECK (user_id <> ''), "
}

func appDml(table: in String): String {
  return "GRANT SELECT, INSERT, UPDATE, DELETE ON public." + table + " TO cloudagents_app"
}

/// A tenant-owned table: the CREATE (with `tenant_id` prepended to `body`),
/// forced RLS, the isolation policy, and the service-role grant.
func tenantTable(name: in String, body: in String): slice[String] {
  return [
    "CREATE TABLE public." + name + " (" + tenantCol() + body + ")",
    "ALTER TABLE public." + name + " ENABLE ROW LEVEL SECURITY",
    "ALTER TABLE public." + name + " FORCE ROW LEVEL SECURITY",
    "CREATE POLICY tenant_isolation ON public." + name + " USING (tenant_id = " + tenantSetting() +
      ") WITH CHECK (tenant_id = " +
      tenantSetting() +
      ")",
    appDml(name)
  ]
}

/// A user-owned table: `user_id` prepended to `body`, forced RLS on the user.
func userTable(name: in String, body: in String): slice[String] {
  return [
    "CREATE TABLE public." + name + " (" + userOwnerCol() + body + ")",
    "ALTER TABLE public." + name + " ENABLE ROW LEVEL SECURITY",
    "ALTER TABLE public." + name + " FORCE ROW LEVEL SECURITY",
    "CREATE POLICY user_isolation ON public." + name + " USING (user_id = " + userSetting() +
      ") WITH CHECK (user_id = " +
      userSetting() +
      ")",
    appDml(name)
  ]
}

/// The two policies that let the claim functions (owned by
/// `cloudagents_claimer`) see and lease rows across tenants or users (spec
/// §5.3). Permissive policies combine with OR per role; the isolation policy
/// never matches for the claimer, which has no scope set.
func claimerPolicies(name: in String): slice[String] {
  return [
    "CREATE POLICY claimer_select ON public." + name + " FOR SELECT TO cloudagents_claimer USING (true)",
    "CREATE POLICY claimer_update ON public." + name + " FOR UPDATE TO cloudagents_claimer USING (true)"
  ]
}

func concat(parts: in slice[slice[String]]): slice[String] {
  var acc: slice[String] = []
  for p in parts {
    for s in p {
      acc = acc.append(s)
    }
  }
  return acc
}

// ─── Global tables ──────────────────────────────────────────────────────────
func globalTables(): slice[String] {
  return [
    "GRANT SELECT ON public.schema_migrations TO cloudagents_app",
    "CREATE TABLE public.users (" + "id text PRIMARY KEY CHECK (id <> ''), " + "github_id bigint UNIQUE, " +
      "github_login text NOT NULL DEFAULT '', " +
      "created_at timestamptz NOT NULL DEFAULT now())",
    "GRANT SELECT, INSERT, UPDATE ON public.users TO cloudagents_app",
    "CREATE TABLE public.tenants (" + "id text PRIMARY KEY CHECK (id <> ''), " + "name text NOT NULL, " +
      "kind text NOT NULL CHECK (kind IN ('personal', 'github_org', 'native')), " +
      "github_org_id bigint UNIQUE, " +
      "created_at timestamptz NOT NULL DEFAULT now(), " +
      "CHECK (kind <> 'github_org' OR github_org_id IS NOT NULL))",
    "GRANT SELECT, INSERT, UPDATE ON public.tenants TO cloudagents_app",
    "CREATE TABLE public.memberships (" + "tenant_id text NOT NULL REFERENCES public.tenants (id), " +
      "user_id text NOT NULL REFERENCES public.users (id), " +
      "role text NOT NULL CHECK (role IN ('owner', 'admin', 'member')), " +
      "source text NOT NULL CHECK (source IN ('github', 'native')), " +
      "suspended boolean NOT NULL DEFAULT false, " +
      "created_at timestamptz NOT NULL DEFAULT now(), " +
      "synced_at timestamptz, " +
      "PRIMARY KEY (tenant_id, user_id))",
    "CREATE INDEX memberships_user ON public.memberships (user_id)",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON public.memberships TO cloudagents_app",
    "CREATE TABLE public.invitations (" + "id text PRIMARY KEY, " +
      "tenant_id text NOT NULL REFERENCES public.tenants (id), " +
      "token_hash text NOT NULL UNIQUE, " +
      "github_login text NOT NULL, " +
      "role text NOT NULL CHECK (role IN ('admin', 'member')), " +
      "created_by text NOT NULL REFERENCES public.users (id), " +
      "created_at timestamptz NOT NULL DEFAULT now(), " +
      "expires_at timestamptz NOT NULL, " +
      "accepted_at timestamptz)",
    "CREATE INDEX invitations_tenant ON public.invitations (tenant_id)",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON public.invitations TO cloudagents_app",
    "CREATE TABLE public.session_routes (" + "session_id text PRIMARY KEY, " +
      "tenant_id text NOT NULL REFERENCES public.tenants (id), user_id text NOT NULL, " +
      "callback_token_hash text NOT NULL DEFAULT '')",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON public.session_routes TO cloudagents_app",
    "CREATE TABLE public.github_token_cache (" + "token_hash text PRIMARY KEY, " +
      "user_id text NOT NULL DEFAULT '', " +
      "login text NOT NULL DEFAULT '', " +
      "expires_at timestamptz NOT NULL)",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON public.github_token_cache TO cloudagents_app"
  ]
}

// ─── User-owned tables ──────────────────────────────────────────────────────
func userTables(): slice[String] {
  return concat(
    [
      userTable(
        "credentials",
        "id text NOT NULL, name text NOT NULL, value_encrypted text NOT NULL, " +
          "created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, " +
          "PRIMARY KEY (user_id, id), UNIQUE (user_id, name)"
      ),
      userTable(
        "github_oauth_refresh",
        "refresh_token text NOT NULL, access_expires_at timestamptz NOT NULL, " +
          "refresh_expires_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, PRIMARY KEY (user_id)"
      ),
      userTable(
        "model_listing_cache",
        "provider text NOT NULL, body text NOT NULL, fetched_at timestamptz NOT NULL, " +
          "PRIMARY KEY (user_id, provider)"
      ),
      userTable(
        "user_sync_state",
        "github_synced_at timestamptz, claimed_until timestamptz, " +
          "PRIMARY KEY (user_id), FOREIGN KEY (user_id) REFERENCES public.users (id)"
      ),
      claimerPolicies("user_sync_state"),
      [
        "GRANT SELECT (user_id, github_synced_at, claimed_until), UPDATE (claimed_until) " +
          "ON public.user_sync_state TO cloudagents_claimer",
        "GRANT SELECT (user_id, source) ON public.memberships TO cloudagents_claimer"
      ]
    ]
  )
}

// ─── Tenant-owned tables: sessions and transcript ───────────────────────────
func sessionTables(): slice[String] {
  return concat(
    [
      tenantTable(
        "sessions",
        "id text NOT NULL, user_id text NOT NULL, repo_url text NOT NULL, " +
          "branch text NOT NULL DEFAULT '', container_id text NOT NULL DEFAULT '', harness text NOT NULL, " +
          "model text NOT NULL DEFAULT '', native_session_id text NOT NULL DEFAULT '', " +
          "status text NOT NULL CHECK (status IN ('CREATED', 'CLONING', 'IDLE', 'RUNNING', 'WARM', 'DESTROYED')), " +
          "created_at timestamptz NOT NULL, last_message_at timestamptz NOT NULL, " +
          "profile_id text NOT NULL DEFAULT '', progress_summary text NOT NULL DEFAULT '', " +
          "progress_percent smallint CHECK (progress_percent BETWEEN 0 AND 100), " +
          "is_archived boolean NOT NULL DEFAULT false, group_id text NOT NULL DEFAULT '', " +
          "last_viewed_at timestamptz, parent_session_id text NOT NULL DEFAULT '', " +
          "forked_from_message_id text NOT NULL DEFAULT '', observes_session_id text NOT NULL DEFAULT '', " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      [
        "CREATE INDEX sessions_user ON public.sessions (tenant_id, user_id)",
        "CREATE INDEX sessions_parent ON public.sessions (tenant_id, parent_session_id)"
      ],
      tenantTable(
        "messages",
        "id text NOT NULL, session_id text NOT NULL, role text NOT NULL CHECK (role IN ('user', 'agent')), " +
          "content text NOT NULL, seq bigint NOT NULL CHECK (seq >= 0), created_at timestamptz NOT NULL, " +
          "search_vector tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, content)) STORED, " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      [
        "CREATE INDEX messages_session_seq ON public.messages (tenant_id, session_id, seq)",
        "CREATE INDEX messages_search ON public.messages USING gin (search_vector)"
      ],
      tenantTable(
        "comments",
        "id text NOT NULL, message_id text NOT NULL, session_id text NOT NULL, body text NOT NULL, " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX comments_session ON public.comments (tenant_id, session_id)"],
      tenantTable(
        "todos",
        "id text NOT NULL, session_id text NOT NULL, message_id text NOT NULL DEFAULT '', note text NOT NULL, " +
          "done boolean NOT NULL, created_at timestamptz NOT NULL, " +
          "status text NOT NULL CHECK (status IN ('pending', 'in_progress', 'done')), " +
          "updated_at timestamptz NOT NULL, source text NOT NULL DEFAULT '' CHECK (source IN ('', 'plan')), " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX todos_session_updated ON public.todos (tenant_id, session_id, updated_at)"],
      tenantTable(
        "runs",
        "id text NOT NULL, session_id text NOT NULL, user_id text NOT NULL, prompt_preview text NOT NULL, " +
          "harness text NOT NULL, model text NOT NULL DEFAULT '', " +
          "status text NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')), " +
          "started_at timestamptz NOT NULL, ended_at timestamptz, PRIMARY KEY (tenant_id, id)"
      ),
      [
        "CREATE INDEX runs_session ON public.runs (tenant_id, session_id)",
        "CREATE INDEX runs_user ON public.runs (tenant_id, user_id)"
      ],
      tenantTable(
        "session_repos",
        "id text NOT NULL, session_id text NOT NULL, repo_url text NOT NULL, branch text NOT NULL DEFAULT '', " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, session_id, repo_url)"
      ),
      tenantTable(
        "session_groups",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, parent_id text NOT NULL DEFAULT '', " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX session_groups_user ON public.session_groups (tenant_id, user_id)"],
      tenantTable(
        "session_highlights",
        "id text NOT NULL, session_id text NOT NULL, message_id text NOT NULL DEFAULT '', " +
          "kind text NOT NULL CHECK (kind IN ('discovery', 'issue', 'workaround', 'revert', 'incomplete', 'followup')), " +
          "title text NOT NULL, detail text NOT NULL, created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX session_highlights_session ON public.session_highlights (tenant_id, session_id)"],
      tenantTable(
        "highlight_scans",
        "session_id text NOT NULL, last_seq bigint NOT NULL CHECK (last_seq >= 0), PRIMARY KEY (tenant_id, session_id)"
      ),
      tenantTable(
        "session_events",
        "session_id text NOT NULL, seq bigint NOT NULL CHECK (seq >= 0), event_type text NOT NULL, " +
          "payload text NOT NULL, prev_hash text NOT NULL DEFAULT '', hash text NOT NULL, " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, session_id, seq)"
      ),
      tenantTable(
        "session_attachments",
        "id text NOT NULL, session_id text NOT NULL, message_id text NOT NULL DEFAULT '', file_name text NOT NULL, " +
          "stored_name text NOT NULL, mime_type text NOT NULL, " +
          "kind text NOT NULL CHECK (kind IN ('image', 'document')), " +
          "size_bytes bigint NOT NULL CHECK (size_bytes >= 0), created_at timestamptz NOT NULL, " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      [
        "CREATE INDEX session_attachments_session ON public.session_attachments (tenant_id, session_id)",
        "CREATE INDEX session_attachments_message ON public.session_attachments (tenant_id, message_id)"
      ],
      tenantTable(
        "artifacts",
        "id text NOT NULL, session_id text NOT NULL, file_name text NOT NULL, stored_name text NOT NULL, " +
          "mime_type text NOT NULL, description text NOT NULL DEFAULT '', " +
          "size_bytes bigint NOT NULL CHECK (size_bytes >= 0), created_at timestamptz NOT NULL, " +
          "repo_key text NOT NULL DEFAULT '', owner_user_id text NOT NULL DEFAULT '', PRIMARY KEY (tenant_id, id)"
      ),
      [
        "CREATE INDEX artifacts_session ON public.artifacts (tenant_id, session_id)",
        "CREATE INDEX artifacts_owner_repo ON public.artifacts (tenant_id, owner_user_id, repo_key)"
      ],
      tenantTable(
        "notifications",
        "id text NOT NULL, session_id text NOT NULL, " +
          "level text NOT NULL CHECK (level IN ('info', 'done', 'blocked')), summary text NOT NULL, " +
          "created_at timestamptz NOT NULL, read_at timestamptz, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX notifications_session ON public.notifications (tenant_id, session_id)"]
    ]
  )
}

// ─── Tenant-owned tables: interactive requests ──────────────────────────────
func requestTables(): slice[String] {
  return concat(
    [
      tenantTable(
        "permission_requests",
        "id text NOT NULL, session_id text NOT NULL, tool_name text NOT NULL, input_json text NOT NULL, " +
          "status text NOT NULL CHECK (status IN ('pending', 'allowed', 'denied')), " +
          "updated_input_json text NOT NULL DEFAULT '', note text NOT NULL DEFAULT '', " +
          "created_at timestamptz NOT NULL, decided_at timestamptz, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX permission_requests_session ON public.permission_requests (tenant_id, session_id)"],
      // input_json is matched byte for byte and can exceed a btree entry, so
      // uniqueness is enforced on a digest of it. md5 because a generated
      // column must be IMMUTABLE and sha256 needs convert_to/textsend, which
      // are only STABLE. The digest is a uniqueness key, not a security
      // boundary: a collision could only reject a distinct rule, never admit
      // one, and matching still compares input_json itself.
      tenantTable(
        "permission_rules",
        "id text NOT NULL, session_id text NOT NULL, tool_name text NOT NULL, input_json text NOT NULL, " +
          "input_digest text GENERATED ALWAYS AS (md5(input_json)) STORED, " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id), " +
          "UNIQUE (tenant_id, session_id, tool_name, input_digest)"
      ),
      tenantTable(
        "user_questions",
        "id text NOT NULL, session_id text NOT NULL, question text NOT NULL, options_json text NOT NULL DEFAULT '', " +
          "status text NOT NULL CHECK (status IN ('pending', 'answered', 'timed_out')), " +
          "answer text NOT NULL DEFAULT '', created_at timestamptz NOT NULL, decided_at timestamptz, " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX user_questions_session ON public.user_questions (tenant_id, session_id)"],
      tenantTable(
        "secret_requests",
        "id text NOT NULL, session_id text NOT NULL, name text NOT NULL, reason text NOT NULL DEFAULT '', " +
          "status text NOT NULL CHECK (status IN ('pending', 'approved', 'denied', 'timed_out')), " +
          "created_at timestamptz NOT NULL, decided_at timestamptz, delivered_at timestamptz, " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX secret_requests_session ON public.secret_requests (tenant_id, session_id)"]
    ]
  )
}

// ─── Tenant-owned tables: library, profiles, jobs ───────────────────────────
func libraryTables(): slice[String] {
  return concat(
    [
      tenantTable(
        "prompts",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, body text NOT NULL, " +
          "use_count integer NOT NULL DEFAULT 0 CHECK (use_count >= 0), created_at timestamptz NOT NULL, " +
          "updated_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX prompts_user ON public.prompts (tenant_id, user_id)"],
      tenantTable(
        "prompt_tags",
        "id text NOT NULL, prompt_id text NOT NULL, user_id text NOT NULL, tag text NOT NULL, " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, prompt_id, tag)"
      ),
      ["CREATE INDEX prompt_tags_user_tag ON public.prompt_tags (tenant_id, user_id, tag)"],
      tenantTable(
        "profiles",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, harness text NOT NULL DEFAULT '', " +
          "network_policy text NOT NULL CHECK (network_policy IN ('full', 'none', 'restricted')), " +
          "credential_mode text NOT NULL CHECK (credential_mode IN ('all', 'selected')), " +
          "created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, " +
          "tool_mode text NOT NULL DEFAULT 'all' CHECK (tool_mode IN ('all', 'selected')), " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, user_id, name)"
      ),
      profileLink("profile_credentials", "credential_name"),
      profileLink("profile_tools", "tool_name"),
      profileLink("profile_skills", "skill_id"),
      profileLink("profile_subagents", "subagent_id"),
      profileLink("profile_mcp_servers", "mcp_server_id"),
      tenantTable(
        "skills",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, description text NOT NULL, " +
          "body text NOT NULL, created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, user_id, name)"
      ),
      tenantTable(
        "subagents",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, description text NOT NULL, " +
          "system_prompt text NOT NULL, model text NOT NULL DEFAULT '', created_at timestamptz NOT NULL, " +
          "updated_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, user_id, name)"
      ),
      tenantTable(
        "mcp_servers",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, " +
          "transport text NOT NULL CHECK (transport IN ('stdio', 'url')), command text NOT NULL DEFAULT '', " +
          "url text NOT NULL DEFAULT '', created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, " +
          "enabled boolean NOT NULL DEFAULT true, PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, user_id, name)"
      ),
      mcpServerPart("mcp_server_args"),
      mcpServerPart("mcp_server_env"),
      mcpServerPart("mcp_server_headers"),
      tenantTable(
        "memories",
        "id text NOT NULL, user_id text NOT NULL, repo_key text NOT NULL, mem_key text NOT NULL, " +
          "value text NOT NULL, created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, user_id, repo_key, mem_key)"
      ),
      tenantTable(
        "repo_tasks",
        "id text NOT NULL, user_id text NOT NULL, repo_key text NOT NULL, description text NOT NULL, " +
          "status text NOT NULL CHECK (status IN ('open', 'done')), created_at timestamptz NOT NULL, " +
          "updated_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX repo_tasks_user_repo_status ON public.repo_tasks (tenant_id, user_id, repo_key, status)"],
      tenantTable(
        "scheduled_jobs",
        "id text NOT NULL, user_id text NOT NULL, name text NOT NULL, prompt text NOT NULL, " +
          "profile_id text NOT NULL DEFAULT '', repo_url text NOT NULL DEFAULT '', branch text NOT NULL DEFAULT '', " +
          "harness text NOT NULL DEFAULT '', model text NOT NULL DEFAULT '', run_at timestamptz, " +
          "interval_seconds integer CHECK (interval_seconds > 0), next_run_at timestamptz, " +
          "last_run_at timestamptz, session_id text NOT NULL DEFAULT '', " +
          "status text NOT NULL CHECK (status IN ('active', 'paused', 'cancelled', 'completed')), " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      [
        "CREATE INDEX scheduled_jobs_user ON public.scheduled_jobs (tenant_id, user_id)",
        "CREATE INDEX scheduled_jobs_due ON public.scheduled_jobs (status, next_run_at)"
      ],
      // Claimed by claim_scheduled_jobs (§5.3a), which advances the schedule
      // itself: the claimer reads the scheduling columns and writes only
      // next_run_at, last_run_at and status.
      claimerPolicies("scheduled_jobs"),
      [
        "GRANT SELECT (tenant_id, id, user_id, status, next_run_at, last_run_at, interval_seconds), " +
          "UPDATE (next_run_at, last_run_at, status) ON public.scheduled_jobs TO cloudagents_claimer"
      ],
      tenantTable(
        "webhooks",
        "id text NOT NULL, user_id text NOT NULL, url text NOT NULL, created_at timestamptz NOT NULL, " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, user_id, url)"
      ),
      tenantTable(
        "webhook_events",
        "id text NOT NULL, user_id text NOT NULL, session_id text NOT NULL, run_id text NOT NULL, " +
          "status text NOT NULL CHECK (status IN ('succeeded', 'failed', 'cancelled')), " +
          "delivered boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX webhook_events_pending ON public.webhook_events (tenant_id, user_id, delivered)"]
    ]
  )
}

func profileLink(name: in String, col: in String): slice[String] {
  return concat(
    [
      tenantTable(
        name,
        "id text NOT NULL, profile_id text NOT NULL, user_id text NOT NULL, " + col + " text NOT NULL, " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, profile_id, " +
          col +
          ")"
      )
    ]
  )
}

func mcpServerPart(name: in String): slice[String] {
  return concat(
    [
      tenantTable(
        name,
        "id text NOT NULL, mcp_server_id text NOT NULL, user_id text NOT NULL, " +
          "position integer NOT NULL CHECK (position >= 0), value text NOT NULL, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX " + name + "_server ON public." + name + " (tenant_id, mcp_server_id)"]
    ]
  )
}

// ─── Tenant-owned tables: capture handoff ───────────────────────────────────
/// The graph-ingest outbox. `body` is canonical JSON whose exact bytes are
/// hashed into `body_hash` and re-sent verbatim. `given_up_at` replaces the
/// SQLite store's `next_attempt_at = '99999999999999'` terminal sentinel, and
/// `claimed_until` is the §5.3 lease.
func outboxTables(): slice[String] {
  return concat(
    [
      tenantTable(
        "graph_ingest_outbox",
        "id text NOT NULL, session_id text NOT NULL, body text NOT NULL, body_hash text NOT NULL, " +
          "url text NOT NULL, created_at timestamptz NOT NULL, attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0), " +
          "next_attempt_at timestamptz NOT NULL, last_error text NOT NULL DEFAULT '', delivered_at timestamptz, " +
          "given_up_at timestamptz, claimed_until timestamptz, " +
          "PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, session_id, body_hash)"
      ),
      [
        "CREATE INDEX graph_ingest_outbox_due ON public.graph_ingest_outbox (next_attempt_at) " +
          "WHERE delivered_at IS NULL AND given_up_at IS NULL"
      ],
      claimerPolicies("graph_ingest_outbox"),
      [
        "GRANT SELECT (tenant_id, id, next_attempt_at, delivered_at, given_up_at, claimed_until), " +
          "UPDATE (claimed_until) ON public.graph_ingest_outbox TO cloudagents_claimer"
      ]
    ]
  )
}

// ─── Tenant-owned tables: session ledger ────────────────────────────────────
func ledgerTables(): slice[String] {
  return concat(
    [
      tenantTable(
        "ledger_sessions",
        "session_id text NOT NULL, seq bigint NOT NULL DEFAULT 0 CHECK (seq >= 0), " +
          "policy_status text NOT NULL DEFAULT '' CHECK (policy_status IN ('', 'absent', 'loaded', 'invalid')), " +
          "policy_json text NOT NULL DEFAULT '', policy_error text NOT NULL DEFAULT '', " +
          "created_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, session_id)"
      ),
      tenantTable(
        "ledger_items",
        "session_id text NOT NULL, item_id text NOT NULL, title text NOT NULL, url text NOT NULL DEFAULT '', " +
          "state text NOT NULL CHECK (state IN ('queued', 'in_progress', 'pr_open', 'done', 'blocked', 'needs_human', 'skipped')), " +
          "blocked_by text NOT NULL DEFAULT '[]', blocked_reason text NOT NULL DEFAULT '', " +
          "prerequisite_proposal text NOT NULL DEFAULT '', recommendation text NOT NULL DEFAULT '', " +
          "pr_url text NOT NULL DEFAULT '', ord integer NOT NULL CHECK (ord >= 0), created_at timestamptz NOT NULL, " +
          "updated_at timestamptz NOT NULL, updated_seq bigint NOT NULL CHECK (updated_seq >= 0), " +
          "PRIMARY KEY (tenant_id, session_id, item_id)"
      ),
      tenantTable(
        "ledger_entries",
        "id text NOT NULL, session_id text NOT NULL, item_id text NOT NULL, " +
          "kind text NOT NULL CHECK (kind IN ('decision', 'deviation', 'shortcut', 'blocker', 'question', 'note')), " +
          "severity text NOT NULL CHECK (severity IN ('info', 'review', 'blocking')), " +
          "declared_severity text NOT NULL DEFAULT '' CHECK (declared_severity IN ('', 'info', 'review', 'blocking')), " +
          "summary text NOT NULL, detail text NOT NULL DEFAULT '', options_json text NOT NULL DEFAULT '[]', " +
          "chosen text NOT NULL DEFAULT '', rationale text NOT NULL DEFAULT '', recommendation text NOT NULL DEFAULT '', " +
          "proceeding_with text NOT NULL DEFAULT '', reversible boolean, files_json text NOT NULL DEFAULT '[]', " +
          "tags_json text NOT NULL DEFAULT '[]', source text NOT NULL CHECK (source IN ('declared', 'observed', 'system')), " +
          "undeclared boolean NOT NULL, matched_entry_id text NOT NULL DEFAULT '', " +
          "origin text NOT NULL DEFAULT '' CHECK (origin IN ('', 'transition')), supersedes text NOT NULL DEFAULT '', " +
          "transcript_seq bigint CHECK (transcript_seq >= 0), " +
          "review_state text NOT NULL CHECK (review_state IN ('pending', 'approved', 'rejected', 'commented', 'not_required', 'resolved')), " +
          "review_by text NOT NULL DEFAULT '', review_at timestamptz, review_comment text NOT NULL DEFAULT '', " +
          "created_at timestamptz NOT NULL, created_seq bigint NOT NULL CHECK (created_seq >= 0), " +
          "updated_seq bigint NOT NULL CHECK (updated_seq >= 0), observed_from bigint CHECK (observed_from >= 0), " +
          "confidence numeric(4,3) CHECK (confidence BETWEEN 0 AND 1), evidence text NOT NULL DEFAULT '', " +
          "provisional boolean, PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX ledger_entries_session ON public.ledger_entries (tenant_id, session_id, review_state)"],
      tenantTable(
        "ledger_transitions",
        "id text NOT NULL, session_id text NOT NULL, item_id text NOT NULL, from_state text NOT NULL, " +
          "to_state text NOT NULL, actor text NOT NULL CHECK (actor IN ('agent', 'human', 'github-sync')), " +
          "reason text NOT NULL DEFAULT '', at timestamptz NOT NULL, seq bigint NOT NULL CHECK (seq >= 0), " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX ledger_transitions_item ON public.ledger_transitions (tenant_id, session_id, item_id)"],
      tenantTable(
        "ledger_feedback",
        "id text NOT NULL, session_id text NOT NULL, entry_id text NOT NULL DEFAULT '', item_id text NOT NULL, " +
          "kind text NOT NULL CHECK (kind IN ('approve', 'reject', 'comment', 'directive')), body text NOT NULL, " +
          "created_by text NOT NULL, created_at timestamptz NOT NULL, delivered_at timestamptz, " +
          "delivered_via text NOT NULL DEFAULT '' CHECK (delivered_via IN ('', 'mcp_poll')), " +
          "delivery_batch text NOT NULL DEFAULT '', updated_seq bigint NOT NULL CHECK (updated_seq >= 0), " +
          "PRIMARY KEY (tenant_id, id)"
      ),
      ["CREATE INDEX ledger_feedback_session ON public.ledger_feedback (tenant_id, session_id, delivered_at)"],
      tenantTable(
        "ledger_github_sync",
        "session_id text NOT NULL, item_id text NOT NULL, synced_label text NOT NULL DEFAULT '', " +
          "comment_id text NOT NULL DEFAULT '', comment_hash text NOT NULL DEFAULT '', " +
          "last_error text NOT NULL DEFAULT '', synced_at timestamptz, attempted_at timestamptz, " +
          "PRIMARY KEY (tenant_id, session_id, item_id)"
      ),
      tenantTable(
        "ledger_github_sync_runs",
        "session_id text NOT NULL, attempted_at timestamptz, last_error text NOT NULL DEFAULT '', " +
          "lease_until timestamptz, PRIMARY KEY (tenant_id, session_id)"
      ),
      // config_key replaces the SQLite column misnamed config_hash: it is the
      // plain `harness|model|repoAccess` string, not a hash.
      tenantTable(
        "ledger_observer",
        "session_id text NOT NULL, observer_session_id text NOT NULL DEFAULT '', " +
          "cursor_seq bigint CHECK (cursor_seq >= 0), window_end bigint CHECK (window_end >= 0), " +
          "pending boolean NOT NULL DEFAULT false, pass_day integer CHECK (pass_day >= 0), " +
          "passes_today integer NOT NULL DEFAULT 0 CHECK (passes_today >= 0), last_pass_at timestamptz, " +
          "config_key text NOT NULL DEFAULT '', last_error text NOT NULL DEFAULT '', " +
          "PRIMARY KEY (tenant_id, session_id)"
      ),
      tenantTable(
        "ledger_observer_settings",
        "profile_id text NOT NULL, enabled boolean NOT NULL, harness text NOT NULL, model text NOT NULL DEFAULT '', " +
          "repo_access text NOT NULL CHECK (repo_access IN ('none', 'diff', 'workspace')), " +
          "mid_run_minutes integer NOT NULL CHECK (mid_run_minutes IN (0, 15, 30, 60)), " +
          "max_passes_per_day integer NOT NULL CHECK (max_passes_per_day BETWEEN 1 AND 500), " +
          "updated_at timestamptz NOT NULL, PRIMARY KEY (tenant_id, profile_id)"
      )
    ]
  )
}

// ─── Claim functions (spec §5.3) ────────────────────────────────────────────
//
// Each is SECURITY DEFINER, owned by the NOLOGIN claimer role (not the table
// owner: FORCE ROW LEVEL SECURITY binds the owner too, so an owner-owned
// function would see nothing), with a fixed search_path and schema-qualified
// names, EXECUTE for the service role only, a bounded limit and lease, and a
// result of scope keys only. The lease (claimed_until) is set in the same
// statement that selects the rows, because the SKIP LOCKED row lock alone is
// released when the claim's transaction commits.
func claimOutboxFn(): String {
  return "CREATE FUNCTION public.claim_graph_ingest_outbox(p_limit integer, p_lease_seconds integer) " +
    "RETURNS TABLE (tenant_id text, id text) LANGUAGE sql SECURITY DEFINER " +
    "SET search_path = pg_catalog, pg_temp AS $fn$ " +
    "UPDATE public.graph_ingest_outbox AS o " +
    "SET claimed_until = pg_catalog.now() + pg_catalog.make_interval(secs => " +
    "LEAST(GREATEST(p_lease_seconds, 1), 3600)) " +
    "FROM (SELECT q.tenant_id, q.id FROM public.graph_ingest_outbox AS q " +
    "WHERE q.delivered_at IS NULL AND q.given_up_at IS NULL AND q.next_attempt_at <= pg_catalog.now() " +
    "AND (q.claimed_until IS NULL OR q.claimed_until < pg_catalog.now()) " +
    "ORDER BY q.next_attempt_at LIMIT LEAST(GREATEST(p_limit, 0), 100) FOR UPDATE SKIP LOCKED) AS d " +
    "WHERE o.tenant_id = d.tenant_id AND o.id = d.id " +
    "RETURNING o.tenant_id, o.id $fn$"
}

func claimMembershipSyncFn(): String {
  return "CREATE FUNCTION public.claim_membership_sync(p_limit integer, p_lease_seconds integer) " +
    "RETURNS TABLE (user_id text) LANGUAGE sql SECURITY DEFINER " +
    "SET search_path = pg_catalog, pg_temp AS $fn$ " +
    "UPDATE public.user_sync_state AS s " +
    "SET claimed_until = pg_catalog.now() + pg_catalog.make_interval(secs => " +
    "LEAST(GREATEST(p_lease_seconds, 1), 3600)) " +
    "FROM (SELECT q.user_id FROM public.user_sync_state AS q " +
    "WHERE (q.github_synced_at IS NULL OR q.github_synced_at < pg_catalog.now() - interval '1 hour') " +
    "AND (q.claimed_until IS NULL OR q.claimed_until < pg_catalog.now()) " +
    "AND EXISTS (SELECT 1 FROM public.memberships AS m WHERE m.user_id = q.user_id AND m.source = 'github') " +
    "ORDER BY q.github_synced_at NULLS FIRST LIMIT LEAST(GREATEST(p_limit, 0), 100) " +
    "FOR UPDATE OF q SKIP LOCKED) AS d " +
    "WHERE s.user_id = d.user_id " +
    "RETURNING s.user_id $fn$"
}

/// Scheduled jobs (§5.3a) are claimed by advancing their schedule rather than
/// leasing them, since a run can take up to 30 minutes: in one statement the
/// claim stamps `last_run_at` with the firing time and moves `next_run_at` to
/// the first slot on the job's cadence after it (a one-shot job becomes
/// `completed` with no next run), so no other caller can fire the same slot
/// and an interrupted run is never re-fired. It returns the scope keys plus
/// the slot and `last_run_at` it replaced, which a skipped run needs to
/// release the claim. The firing time is truncated to milliseconds, the
/// precision every store timestamp round-trips at, so a release can match it.
func claimScheduledJobsFn(): String {
  return "CREATE FUNCTION public.claim_scheduled_jobs(p_limit integer) " +
    "RETURNS TABLE (tenant_id text, id text, user_id text, due_at timestamptz, previous_last_run_at timestamptz) " +
    "LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $fn$ " +
    "UPDATE public.scheduled_jobs AS j SET last_run_at = pg_catalog.date_trunc('milliseconds', pg_catalog.now()), " +
    "next_run_at = CASE WHEN j.interval_seconds IS NULL THEN NULL ELSE d.next_run_at + " +
    "pg_catalog.make_interval(secs => j.interval_seconds * (pg_catalog.floor(pg_catalog.date_part('epoch', " +
    "pg_catalog.date_trunc('milliseconds', pg_catalog.now()) - d.next_run_at) / j.interval_seconds) + 1)) END, " +
    "status = CASE WHEN j.interval_seconds IS NULL THEN 'completed' ELSE j.status END " +
    "FROM (SELECT q.tenant_id, q.id, q.next_run_at, q.last_run_at FROM public.scheduled_jobs AS q " +
    "WHERE q.status = 'active' AND q.next_run_at <= pg_catalog.now() " +
    "ORDER BY q.next_run_at LIMIT LEAST(GREATEST(p_limit, 0), 100) FOR UPDATE SKIP LOCKED) AS d " +
    "WHERE j.tenant_id = d.tenant_id AND j.id = d.id " +
    "RETURNING j.tenant_id, j.id, j.user_id, d.next_run_at, d.last_run_at $fn$"
}

func claimFunctions(): slice[String] {
  return [
    claimOutboxFn(),
    claimMembershipSyncFn(),
    claimScheduledJobsFn(),
    // Privileges first, while cloudagents_owner still owns the functions: a
    // GRANT/REVOKE by a non-owner is silently a no-op (with only a warning),
    // which would leave EXECUTE with PUBLIC. ALTER ... OWNER TO then carries
    // the ACL across to the new owner.
    "REVOKE ALL ON FUNCTION public.claim_graph_ingest_outbox(integer, integer) FROM PUBLIC",
    "REVOKE ALL ON FUNCTION public.claim_membership_sync(integer, integer) FROM PUBLIC",
    "REVOKE ALL ON FUNCTION public.claim_scheduled_jobs(integer) FROM PUBLIC",
    "GRANT EXECUTE ON FUNCTION public.claim_graph_ingest_outbox(integer, integer) TO cloudagents_app",
    "GRANT EXECUTE ON FUNCTION public.claim_membership_sync(integer, integer) TO cloudagents_app",
    "GRANT EXECUTE ON FUNCTION public.claim_scheduled_jobs(integer) TO cloudagents_app",
    // ALTER ... OWNER TO needs the new owner to hold CREATE on the schema;
    // grant it only for the ownership change.
    "GRANT CREATE ON SCHEMA public TO cloudagents_claimer",
    "ALTER FUNCTION public.claim_graph_ingest_outbox(integer, integer) OWNER TO cloudagents_claimer",
    "ALTER FUNCTION public.claim_membership_sync(integer, integer) OWNER TO cloudagents_claimer",
    "ALTER FUNCTION public.claim_scheduled_jobs(integer) OWNER TO cloudagents_claimer",
    "REVOKE CREATE ON SCHEMA public FROM cloudagents_claimer"
  ]
}

/// The one-off SQLite export runs as the BYPASSRLS migrator (spec §7): it may
/// read (for its precondition and count checks) and insert, nothing else.
func migratorGrants(): slice[String] {
  return ["GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO cloudagents_migrator"]
}

func baselineStatements(): slice[String] {
  return concat(
    [
      globalTables(),
      userTables(),
      sessionTables(),
      requestTables(),
      libraryTables(),
      outboxTables(),
      ledgerTables(),
      claimFunctions(),
      migratorGrants()
    ]
  )
}
