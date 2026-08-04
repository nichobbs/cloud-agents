# Phase 9 — Full-text search across message transcripts

Status: shipped (migration, backend route, frontend page, and tests). Not
yet run through the real `lyric` toolchain — see "Verification status" at
the end.

## 1. Problem

Every message a session has ever exchanged lives in `messages`, but the only
way to find one again is to open the right session and scroll. The user
asked for a way to search across every message in their *own* sessions —
`GET /api/search/messages?q=...` — with a matching frontend page.

## 2. Storage: a standalone FTS5 index, not "external content" mode

SQLite's FTS5 extension is already available in this codebase's vaulted
native build (`SourceGear.sqlite3` 3.53.3) but had never been exercised
here. Availability, and the design below, were confirmed directly: the
actual vaulted `linux-x64` native library was extracted and driven straight
through the C API via Python `ctypes` — both finding `ENABLE_FTS5`/
`sqlite3Fts5Init` compiled in, and actually executing a
`CREATE VIRTUAL TABLE ... USING fts5`, inserts, and `MATCH` queries against
it, rather than relying on documentation alone.

Migration `0028_message_search` adds:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(content, id UNINDEXED)

INSERT INTO messages_fts(content, id) SELECT content, id FROM messages

CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(content, id) VALUES (new.content, new.id);
END
```

This is a **standalone** FTS5 table — not FTS5's "external content" mode
(`content='messages', content_rowid='rowid'`). External-content mode avoids
duplicating `content` on disk, but ties correctness to `messages`'s implicit
rowid staying stable and needs INSERT/UPDATE/DELETE triggers all kept in
perfect sync. A full-codebase grep confirms `messages` is INSERT-only — no
UPDATE or DELETE statement touches it anywhere — so only an `AFTER INSERT`
trigger is actually needed, and storing `content` + `id` directly in the
FTS5 table sidesteps the rowid-linkage question entirely. Simpler and more
robust for a feature with no local toolchain available to catch a subtly
wrong trigger set before it ships. `id` is `UNINDEXED` — carried through
purely to join back to `messages` for the authoritative row (role/seq/
created_at are read from there, not duplicated into the index).

All three statements run inside `runMigrations()`'s single
`executeTransaction` call, atomically with the rest of the migration ledger
— there is no window where a message could be inserted between the table
being created and the backfill running.

## 3. Query safety: no bound-parameter layer

This codebase has no bound-parameter/prepared-statement layer anywhere —
every SQL builder in `CloudAgents.Db` takes raw values and escapes them via
`sqlLiteral()` (doubling embedded `'`), and `searchMessagesSql` follows the
same convention for embedding the MATCH expression as a SQL string literal.

That only makes the *SQL* safe, though — FTS5 has its own query mini-language
inside a MATCH string (`AND`/`OR`/`NOT`, `*` prefix search, `column:` filters,
quoting), which `sqlLiteral()` knows nothing about. A raw user search term
passed straight into `MATCH` would let a search box double as an FTS5 query
console (and, via quote characters, as an FTS5 syntax-injection vector even
before touching SQL string-literal escaping).

`CloudAgents.Search.buildFts5MatchExpr` closes that gap: the input is
hand-split on whitespace (no `String.split()` — see §5), and each word is
wrapped as a **quoted-prefix token** — `"word"*` — by
`fts5EscapeWord`, which also doubles any embedded `"` (FTS5's own quoting
rule, the same shape as `sqlLiteral`'s `'`-doubling). A quoted string in
FTS5 is always literal text, so this disables every operator (`AND`/`OR`/
`NOT`/`*`/`column:`) *inside* the quotes; the trailing `*` sits outside the
quotes, where FTS5 still treats "a quoted literal immediately followed by
`*`" as a prefix query — preserving useful prefix-matching UX ("sched" finds
"scheduled") without reopening operator interpretation. Multiple words are
joined with a space, which FTS5 treats as an implicit `AND`.

This was verified against the same real native SQLite build as §2, with
hostile inputs: embedded quotes, bare `AND`/`OR`/`NOT`, colons, and a
literal quote-injection attempt (`a" OR content MATCH "x`) — all came back
as inert literal text, never reinterpreted as query syntax.

An empty or whitespace-only term produces `buildFts5MatchExpr("") == ""`,
which is itself an FTS5 syntax error at the database
(`fts5: syntax error near ''`, confirmed directly) — so
`searchMessagesHandler` rejects an empty/whitespace `q` with 400 before it
ever reaches `CloudAgents.Db.searchMessagesSql`.

## 4. The query and route

```sql
SELECT m.id, m.session_id, m.role, m.content, m.seq, m.created_at
FROM messages_fts f JOIN messages m ON m.id = f.id JOIN sessions s ON s.id = m.session_id
WHERE f.content MATCH :matchExpr AND s.user_id = :userId
ORDER BY m.created_at DESC LIMIT :limit
```

`messages` carries no `user_id` of its own, so ownership is enforced with a
`JOIN` through to `sessions` — the same join-for-ownership shape
`selectPromptsByTagSql` already uses elsewhere in this file. `limit` is an
internal, app-controlled constant (`maxSearchResults = 50`, never
client-supplied — an attacker-controlled `LIMIT` would be a resource-
exhaustion vector), so it's inlined as a bare integer literal rather than
through `sqlLiteral()` (which would quote it as TEXT).

`GET /api/search/messages?q=...` (`CloudAgents.Search.searchMessagesHandler`,
registered before the `AuthMiddleware` wrap in `main.l`, like every other
route) validates `q` (required, ≤200 chars), builds the MATCH expression,
and returns the results as a `CloudAgents.Repository.MessageList` — the
exact same response shape `GET /api/sessions/{id}/messages` already uses,
so no new response record or JSON serialization code was needed.

## 5. Lyric implementation notes

- No `String.split()` — unproven in this codebase (`docs/lyric/gotchas.md`
  catalogs several documented-but-broken `String` methods). `buildFts5MatchExpr`
  hand-rolls its whitespace scan instead, mirroring the already-proven
  character-scan idiom in `CloudAgents.Text.indexOfFrom`.
- `term.length` is normalized to `Int` via `.toInt()` immediately, rather
  than mixing `Nat` and `Int` arithmetic in the scan loop (a documented
  source of compile errors / `InvalidProgramException` elsewhere in this
  codebase).

## 6. Frontend

`Search.tsx` (modeled on `Prompts.tsx`'s load/loading/error pattern): a
single search box, `api.searchMessages(term)` (`GET /api/search/messages?q=`),
and a result list — each result links to `/sessions/{sessionId}` so a match
can be opened in its original context. Added to `App.tsx`'s routes and
`Nav.tsx`'s nav bar.

## 7. Verification status

Compile-time only, in the same sense several other phases' entries in
`docs/PROGRESS.md` are qualified: this environment has no `lyric` toolchain
installed, so the backend change has not yet been run through `lyric build`/
`lyric test`/`scripts/verify.sh`. Unlike most prior phases, though, the two
riskiest pieces of this design — FTS5 availability itself, and the
MATCH-expression escaping scheme — were verified directly against the real
production SQLite binary via `ctypes` (§2, §3), not just by analogy to other
proven Lyric code. `tests/search_tests.l` covers `buildFts5MatchExpr`
directly (single/multi-word, embedded quotes, FTS5 operator/column-filter
neutralization, empty/whitespace input) and `searchMessagesHandler`
end-to-end against a live test database (validation errors, no-match,
matching with newest-first ordering, prefix matching, and cross-user
ownership isolation) — it just hasn't been executed by a real compiler yet.
The frontend half (`npx tsc --noEmit`, `npm run build`, and the full
`npm test` suite) *has* actually run, since the JS/TS toolchain is
available in this environment.
