# Spec: per-tool permission enrichment

Status: **Derivation + accessor implemented; checkpoint attachment deferred
(cross-repo).** The "audit-row enrichment" follow-up of the provenance-capture
work (Testamur §4.1 / ADR-0004; `docs/CAPABILITY_AUDIT.md` WP4), building on the
checkpoint bridge (`docs/capture-checkpoint.md`) and the capture core
(`docs/capture-stream-json.md`).

## 1. Purpose and scope

`CloudAgents.CheckpointBridge` maps a captured session to the Testamur
checkpoint format through the vendored `Adapt.mapStreamJson`. That mapper stamps
a **single** context-level tool-use permission (`granted` | `denied` | `auto`,
via `InvocationContext.permission`) onto every `tool_use` step of the session —
one blanket mode for the whole run. But the runner already records finer
evidence, one row per decision:

- **`permission_requests`** — one row per prompted `(tool, input)` pair
  (`toolName`, `status`), decided `allowed` or `denied`. The host-side timeout
  backstop rewrites a timed-out prompt's `status` to `denied` (with an
  explanatory note), so `pending`/`allowed`/`denied` are the statuses seen here.
- **`secret_requests`** — one row per `request_secret` credential ask (`name`,
  `reason`, `status`), decided `approved` or `denied`, or swept to `timed_out`.

This work package folds those per-request rows into a **per-tool permission
map**: which tools the session was actually granted, denied, or left to auto,
rather than one context-level mode.

**In scope:** a pure derivation (`derivePermissions`), the two status→permission
mappers, the `permissionForTool` accessor, the `request_secret:<name>` key
convention, and one thin DB-facing convenience (`permissionsForSession`) that
reads a session's rows and folds them. All in `CloudAgents.PermissionEnrichment`
(`src/capture/permission_enrichment.l`).

**Out of scope / deferred:** attaching the derived map to the emitted checkpoint
steps — see §7. Also: promoting `permission` to a per-(tool, input) granularity;
folding `user_questions` rows; and any UI surface.

## 2. Data source rows

Both tables are session-scoped and already have oldest-first session accessors
(`CloudAgents.Repository.permissionRequestsCreatedAfter` /
`secretRequestsCreatedAfter`). This package reuses them with the empty cursor
(`created_at > ''` matches every row, since `created_at` is always a non-empty
millis string), so **no new SQL** is added. Neither table stores a credential
value — `secret_requests` is the audit trail (name/reason/status/timestamps)
only.

## 3. Status → permission

The checkpoint `Permission` is a closed set `granted | denied | auto`. Only an
**explicit human decision** claims `granted`/`denied`; everything else is
`auto` — the least-claiming value, matching the vendored adapter's stated
philosophy ("claiming granted would assert an explicit human grant the record
does not show").

| Table | status | → `Permission` |
|---|---|---|
| `permission_requests` | `allowed` | `Granted` |
| `permission_requests` | `denied` (incl. timed-out-to-denied) | `Denied` |
| `permission_requests` | `pending` / other | `Auto` |
| `secret_requests` | `approved` | `Granted` |
| `secret_requests` | `denied` | `Denied` |
| `secret_requests` | `timed_out` / `pending` / other | `Auto` |

Note the deliberate asymmetry for timeouts: the permission-request timeout sweep
materializes `denied` in the row itself, so a timed-out prompt presents as
`Denied`; the secret-request sweep uses a distinct `timed_out` status, which
presents as `Auto` (no explicit human decision was recorded). This faithfully
reflects the source data rather than inventing a decision.

**Tool key.** A `permission_requests` row keys under its `toolName` (the
checkpoint `tool_use` tool). A `secret_requests` row keys under the synthetic
`request_secret:<name>` (secret asks flow through the `request_secret` MCP tool)
— distinct from real tool permissions, and it keeps the credential name for
audit rather than collapsing every ask onto one key.

## 4. Fold (per-tool aggregation)

Per-tool-name aggregation is inherently lossy (a tool prompted for several
different inputs collapses to one key). When one key has several rows they fold
with a **conservative precedence `Denied > Granted > Auto`**: a tool denied even
once always surfaces as denied — the audit-safe reading. The fold is
order-independent, and the derived list is sorted by tool key so the output is
deterministic regardless of row-insertion timing.

`permissionForTool(map, tool)` returns a key's folded outcome, or `Auto` for a
tool with no request row — an unprompted tool was auto-approved and never claims
an explicit grant/denial, which is exactly the mapper's existing default for a
step whose tool was never gated.

## 5. API (`CloudAgents.PermissionEnrichment`)

- `pub record ToolPermission { tool: String; permission: Permission }` — one
  tool's derived outcome (`Permission` from `Testamur.CheckpointFormat.Model`).
- `permissionOfStatus(status) -> Permission`,
  `permissionOfSecretStatus(status) -> Permission` — the §3 mappers.
- `secretToolKey(name) -> String` — the `request_secret:<name>` convention.
- `derivePermissions(rows: List[ToolPermission]) -> List[ToolPermission]` — the
  §4 fold (pure; no DB, no clock).
- `permissionForTool(map, tool) -> Permission` — the accessor (default `Auto`).
- `permissionsForSession(sessionId) -> Result[List[ToolPermission], DbError]` —
  the DB-facing convenience: read both tables for the session, map each row to a
  `ToolPermission`, and `derivePermissions`.

## 6. Test strategy (two tiers, matching the repo)

- **Offline** (`tests/permission_enrichment_tests.l`, no DB/network/clock): the
  two status mappers over every status; the `request_secret:<name>` key; the
  fold (distinct tools → one sorted entry each; a tool denied once folds to
  denied; granted beats auto but not denied; order-independence; empty input →
  empty map); and `permissionForTool` (folded outcome; `Auto` for an unknown
  tool).
- **Live-SQLite** (same fresh-temp-DB harness as
  `tests/session_events_tests.l`, gated on the native SQLite lib): create +
  answer real `permission_requests` / `secret_requests` rows through the
  repository, then `permissionsForSession` derives the expected per-tool map
  (allowed→granted, denied→denied, still-pending→auto, approved secret→granted
  under `request_secret:<name>`); a different session is isolated; two Bash
  prompts (one allowed, one denied) fold to denied.

## 7. Attachment point (deferred, cross-repo)

Attaching the derived map to the emitted checkpoint would replace, per
`tool_use` step, the blanket `context.permission` with
`permissionForTool(map, step.tool)`. The step-`permission` assignment lives in
`Adapt.mapStreamJson` (`mapEvents` / `flushPending`), which is **vendored
verbatim** from the platform (`vendor/testamur-checkpoint-format/`) — the
drift-guard whose whole point is that the content addresses this repo emits are
byte-identical to the ones testamur computes for the same input. The vendored
mapper supports only one session-level permission; teaching it a per-tool map
(and re-deriving the content addresses that follow) is a change to the shared
checkpoint-format contract, so it belongs upstream in testamur, not as a local
fork of the vendored copy. This package therefore ships the derivation +
accessor now; `permissionForTool` is precisely the seam that the future mapper
integration calls per step once the contract lands. Sequenced with the other
capture follow-ups in `AGENTS.md`.

## 8. Acceptance criteria

1. `permissionOfStatus` / `permissionOfSecretStatus` map every documented status
   per §3, defaulting unknown statuses to `Auto`.
2. `derivePermissions` yields one entry per distinct tool key, folded with
   `Denied > Granted > Auto`, order-independent, sorted by key.
3. `permissionForTool` returns a key's folded outcome and `Auto` for an
   unknown tool.
4. `permissionsForSession` folds a session's real permission + secret rows into
   the expected map, isolated per session (live-SQLite).
5. Offline suite passes with no DB.
