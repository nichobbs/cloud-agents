//! Tests for importing findings about Claude Code cloud sessions
//! (docs/claude-session-import.md): secret redaction (§12), and how a chunk of
//! candidates is judged, including restart dedup (§4.3). Pure: no database.
@test_module
package CloudAgents.LedgerImportTests

import Std.Core
import Std.Testing
import CloudAgents.Pg
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Reconcile
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.Redact
import CloudAgents.Ledger.Import
import CloudAgents.Ledger.Observer

func ctx(): SessionContext {
  return SessionContext(
    sessionId = "s1",
    ownerUserId = "u1",
    ownerRepo = "acme/shop",
    tenantScope = TenantScope(tenantId = "personal:u1", userId = "u1")
  )
}

func cand(kind: in String, summary: in String, s: in String, t: in String, conf: in String): Candidate {
  val none: slice[String] = []
  return Candidate(
    kind = kind,
    summary = summary,
    detail = "",
    itemId = "",
    seqStart = s,
    seqEnd = t,
    tags = none,
    files = none,
    reversible = "",
    confidence = conf,
    evidence = ""
  )
}

func observed(id: in String, kind: in String, summary: in String, from: in String, to: in String): LedgerEntry {
  val none: slice[String] = []
  return LedgerEntry(
    id = id,
    sessionId = "s1",
    itemId = "",
    kind = kind,
    severity = "review",
    declaredSeverity = "",
    summary = summary,
    detail = "",
    optionsConsidered = none,
    chosen = "",
    rationale = "",
    recommendation = "",
    proceedingWith = "",
    reversible = "",
    files = none,
    tags = none,
    source = "observed",
    undeclared = "true",
    matchedEntryId = "",
    origin = "",
    supersedes = "",
    transcriptSeq = to,
    reviewState = "pending",
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = "",
    createdSeq = "",
    updatedSeq = "",
    observedFrom = from,
    confidence = "0.8",
    evidence = "",
    provisional = "false"
  )
}

func chunk(from: in Int, through: in Int, restarting: in Bool, cs: in slice[Candidate]): ImportChunk {
  return ImportChunk(fromOrdinal = from.toLong(), throughOrdinal = through.toLong(), restarting = restarting, backfill = true, candidates = cs)
}

// ── Redaction ────────────────────────────────────────────────────────────────
test "prefixed tokens are redacted, short look-alikes are not" {
  assertEqual(redactText("token ghp_abcdefghijklmnopqrstuvwxyz0123 here"), "token [redacted:github-token] here", "ghp_")
  assertEqual(redactText("github_pat_11ABCDEFG0123456789abcdefghij"), "[redacted:github-token]", "github_pat_")
  assertEqual(redactText("key sk-ant-api03-abcdefghijklmnopqrstuv"), "key [redacted:anthropic-key]", "sk-ant-")
  assertEqual(redactText("cai_0123456789abcdef0123"), "[redacted:import-token]", "cai_")
  assertEqual(redactText("the ghp_ prefix"), "the ghp_ prefix", "a bare prefix is not a token")
  assertEqual(redactText("sk-learn is a library"), "sk-learn is a library", "short sk- word")
  assertEqual(redactText("id AKIAABCDEFGHIJKLMNOP done"), "id [redacted:aws-key-id] done", "AWS key id")
  assertEqual(redactText("AKIA is a prefix"), "AKIA is a prefix", "a bare AWS prefix")
}

test "credentials in headers, assignments and URLs are redacted" {
  assertEqual(redactText("Authorization: Bearer abc.def-ghi_jkl"), "Authorization: Bearer [redacted:credential]", "bearer")
  assertEqual(redactText("GITHUB_TOKEN=abcd1234efgh"), "GITHUB_TOKEN=[redacted:secret]", "env assignment")
  assertEqual(redactText("{\"password\": \"hunter22\"}"), "{\"password\": \"[redacted:secret]\"}", "json value")
  assertEqual(redactText("apiToken: s3cr3tvalue"), "apiToken: [redacted:secret]", "camelCase key")
  assertEqual(redactText("max_tokens=4096 and tokens_used: 1200"), "max_tokens=4096 and tokens_used: 1200", "token counts are not secrets")
  assertEqual(redactText("DEBUG_TOKEN=true"), "DEBUG_TOKEN=true", "placeholder values stay")
  assertEqual(redactText("postgres://app:pa55word@db:5432/x"), "postgres://[redacted:credentials]@db:5432/x", "url user info")
  assertEqual(redactText("https://github.com/acme/shop"), "https://github.com/acme/shop", "plain url")
  assertEqual(redactText("https://user@example.com/x"), "https://user@example.com/x", "user without password")
}

test "private key blocks are redacted whole" {
  val pem = "before -----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabc\n-----END RSA PRIVATE KEY----- after"
  assertEqual(redactText(pem), "before [redacted:private-key] after", "PEM block")
  val cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
  assertEqual(redactText(cert), cert, "a certificate is public")
}

test "high-entropy runs are redacted, but not hashes, ids or paths" {
  assertEqual(redactText("x Zk9QmT3vLp7Rw2Xy5Bn8Cd1Fg4Hj6Ks0Ae end"), "x [redacted:high-entropy] end", "mixed run")
  val sha1 = "3f9a1c7e2b8d4f6a0c5e9b1d3f7a2c4e6b8d0f1a"
  assertEqual(redactText("commit " + sha1), "commit " + sha1, "git SHA-1")
  assertEqual(redactText("at 3f9a1c7"), "at 3f9a1c7", "abbreviated SHA")
  val sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  assertEqual(redactText(sha256), sha256, "SHA-256")
  val uuid = "event 1bff672c-94a1-4c3e-8a7b-547bc1f694de: quoted"
  assertEqual(redactText(uuid), uuid, "UUID event id")
  assertEqual(redactText("session_01MzoMEQogKcLSCfXbwQpzew"), "session_01MzoMEQogKcLSCfXbwQpzew", "session id")
  assertEqual(redactText("cse_01MzoMEQogKcLSCfXbwQpzewAbCd"), "cse_01MzoMEQogKcLSCfXbwQpzewAbCd", "cse id")
  val urlPath = "https://example.com/a/Zk9QmT3vLp7Rw2Xy5Bn8Cd1Fg4Hj6Ks0Ae/b"
  assertEqual(redactText(urlPath), urlPath, "a URL path segment")
  assertEqual(redactText("api_key=" + sha1), "api_key=[redacted:secret]", "hex after a secret key name")
}

test "file paths skip the high-entropy rule but not the others" {
  val p = "src/Zk9QmT3vLp7Rw2Xy5Bn8Cd1Fg4Hj6Ks0AeQq.ts"
  assertEqual(redactPath(p), p, "a long segment in a path")
  assertEqual(redactPath("notes/ghp_abcdefghijklmnopqrstuvwxyz0123.txt"), "notes/[redacted:github-token].txt", "a token in a path")
}

test "redaction is idempotent" {
  val samples: slice[String] = [
    "Bearer abcdefghijkl and GITHUB_TOKEN=abcd1234efgh",
    "postgres://app:pa55word@db/x and ghp_abcdefghijklmnopqrstuvwxyz0123",
    "x Zk9QmT3vLp7Rw2Xy5Bn8Cd1Fg4Hj6Ks0Ae end"
  ]
  var i = 0
  while i < samples.length.toInt() {
    val once = redactText(samples[i])
    assertEqual(redactText(once), once, "twice equals once: " + samples[i])
    i = i + 1
  }
}

// ── Chunks ───────────────────────────────────────────────────────────────────
test "a chunk's candidates must lie inside its ordinal range" {
  val none: slice[LedgerEntry] = []
  val cfg = defaultReconcileConfig()
  val ok = acceptImportChunk(ctx(), chunk(10, 19, false, [cand("shortcut", "Skipped the flaky refund test", "10", "19", "0.9")]), none, cfg, 50)
  assertEqual(ok.problem, "", "range edges are inside")
  assertEqualInt(ok.undeclared, 1, "stored")
  val before = acceptImportChunk(ctx(), chunk(10, 19, false, [cand("shortcut", "Skipped a test", "9", "12", "0.9")]), none, cfg, 50)
  assertTrue(before.problem.length.toInt() > 0, "starts before the chunk")
  assertEqualInt(before.toInsert.length.toInt(), 0, "a rejected chunk stores nothing")
  val after = acceptImportChunk(ctx(), chunk(10, 19, false, [cand("shortcut", "Skipped a test", "12", "20", "0.9")]), none, cfg, 50)
  assertTrue(after.problem.length.toInt() > 0, "ends after the chunk")
  val note = acceptImportChunk(ctx(), chunk(0, 5, false, [cand("note", "An aside", "1", "2", "0.9")]), none, cfg, 50)
  assertTrue(note.problem.length.toInt() > 0, "notes are not observable")
}

test "imported findings are undeclared observations, redacted and unlinked" {
  val none: slice[LedgerEntry] = []
  val c = Candidate(
    kind = "shortcut",
    summary = "Pasted GITHUB_TOKEN=abcd1234efgh into a script",
    detail = "",
    itemId = "gh:acme/shop#4",
    seqStart = "3",
    seqEnd = "4",
    tags = ["tests"],
    files = ["src/a.l"],
    reversible = "true",
    confidence = "0.9",
    evidence = "event 1bff672c-94a1-4c3e-8a7b-547bc1f694de: export GITHUB_TOKEN=abcd1234efgh"
  )
  val d = acceptImportChunk(ctx(), chunk(0, 9, false, [c]), none, defaultReconcileConfig(), 50)
  assertEqual(d.problem, "", "accepted")
  val e = d.toInsert[0]
  assertEqual(e.source, "observed", "observed")
  assertEqual(e.undeclared, "true", "undeclared")
  assertEqual(e.provisional, "false", "imports are never provisional")
  assertEqual(e.itemId, "", "work items are not linked")
  assertEqual(e.observedFrom, "3", "from")
  assertEqual(e.transcriptSeq, "4", "to")
  assertEqual(e.summary, "Pasted GITHUB_TOKEN=[redacted:secret] into a script", "summary redacted")
  assertTrue(e.evidence.contains("1bff672c-94a1-4c3e-8a7b-547bc1f694de"), "the event id survives")
  assertTrue(not e.evidence.contains("abcd1234efgh"), "the secret does not")
  assertTrue(e.severity != "info", "undeclared findings need review")
  assertEqualInt(d.notify.length.toInt(), 0, "a backfill notifies nobody")
}

test "low confidence is dropped and repeats within a chunk are duplicates" {
  val none: slice[LedgerEntry] = []
  val cs: slice[Candidate] = [
    cand("shortcut", "Skipped the flaky refund test", "1", "2", "0.9"),
    cand("deviation", "Skipped the flaky refund test again", "2", "3", "0.9"),
    cand("decision", "Maybe used the wrong cache", "7", "7", "0.2")
  ]
  val d = acceptImportChunk(ctx(), chunk(0, 9, false, cs), none, defaultReconcileConfig(), 50)
  assertEqualInt(d.undeclared, 1, "one finding")
  assertEqualInt(d.duplicates, 1, "a shortcut restated as a deviation, overlapping in wording")
  assertEqualInt(d.dropped, 1, "below the confidence floor")
}

test "the range-free duplicate path holds without overlapping seqs" {
  val existing: slice[LedgerEntry] = [observed("o1", "shortcut", "Skipped the flaky refund test", "100", "110")]
  val c = cand("shortcut", "Skipped the flaky refund test", "3", "4", "0.9")
  assertEqual(findDuplicate(c, 3.toLong(), 4.toLong(), existing), "o1", ">= 90% similarity needs no overlap")
}

test "a reworded restatement is a duplicate only while restarting" {
  val existing: slice[LedgerEntry] = [observed("o1", "shortcut", "Skipped the flaky refund test in CI", "100", "110")]
  val c = cand("shortcut", "Disabled the flaky refund test", "3", "4", "0.9")
  val pct = similarityPct(c.summary, existing[0].summary)
  assertTrue(pct >= 50 and pct < 90, "a rewording, not a repeat: " + toString(pct))
  assertEqual(findDuplicateBySimilarity(c, existing, 50), "o1", "similar enough on wording alone")
  val normal = acceptImportChunk(ctx(), chunk(0, 9, false, [c]), existing, defaultReconcileConfig(), 50)
  assertEqualInt(normal.undeclared, 1, "kept outside a restart: different ranges")
  val restart = acceptImportChunk(ctx(), chunk(0, 9, true, [c]), existing, defaultReconcileConfig(), 50)
  assertEqualInt(restart.duplicates, 1, "dropped during a restart")
  assertEqualInt(restart.toInsert.length.toInt(), 0, "nothing stored")
}

test "the importer prompt carries the observer's guidance" {
  assertTrue(importerPrompt().contains(whatToLookFor()), "shared guidance")
  assertTrue(observerPrompt(true).contains(whatToLookFor()), "the observer too")
  assertTrue(importerPrompt().contains("prompt-injection"), "injection is reported, not obeyed")
}
