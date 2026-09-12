//! CloudAgents.GraphIngestOutbox — pure retry/backoff policy for the durable
//! graph-ingest outbox (docs/capture-ingest-outbox.md). This package holds
//! ONLY deterministic, offline logic: computing a bounded exponential
//! backoff delay (with jitter derived from a caller-supplied seed, not real
//! randomness, so the schedule is reproducible in tests), deciding whether a
//! row has exhausted its retry budget, and bounding/labelling a stored error
//! message. It does no DB or HTTP work — `CloudAgents.GraphIngestDrain`
//! (`src/handlers/graph_ingest_drain.l`) is the impure layer that calls into
//! this one.
//!
//! Deliberately `Int`-only, never `Long`: every value here is a millisecond
//! DURATION (bounded well under `maxDelayMillis`), not an absolute epoch
//! timestamp. The one place an absolute timestamp is needed (`next_attempt_at
//! = now + delay`), the addition is pushed into SQL
//! (`CloudAgents.Db.updateGraphIngestOutboxAttemptSql`) — the same "let
//! SQLite's 64-bit arithmetic do it" idiom `scheduled_jobs`' due-date
//! bookkeeping already uses (see `src/db/db_client.l`'s
//! `markScheduledJobRanRecurringSql` doc comment) — rather than adding an
//! `Int` delay to a `Long` epoch millis value in Lyric application code. This
//! isn't strictly required by any confirmed bug (docs/lyric/gotchas.md's
//! `Long` crash entry is about subtract-and-compare inside a large, complex
//! function, not a one-line add in a tiny one), but it costs nothing here and
//! keeps this package (and its test suite) entirely free of `Long`.
package CloudAgents.GraphIngestOutbox

import Std.Core

/// Base retry delay for the first failed attempt.
pub val baseDelayMillis: Int = 30000

/// Backoff ceiling — no row is ever scheduled further out than this.
pub val maxDelayMillis: Int = 3600000

/// Default max-attempts cap (overridable via
/// `CLOUDAGENTS_GRAPH_INGEST_MAX_ATTEMPTS`, see `CloudAgents.GraphIngestDrain`).
pub val defaultMaxAttempts: Int = 50

/// A `next_attempt_at` sentinel far enough in the future (the year 5138) that
/// a terminal row is permanently excluded from `dueGraphIngest`'s
/// `CAST(next_attempt_at AS INTEGER) <= CAST(now AS INTEGER)` filter, without
/// needing a separate `terminal` column.
pub val terminalSentinelMillis: String = "99999999999999"

/// Cap on the stored `last_error` length — bounds row size against a very
/// long HTTP/transport error message. `httpPostJsonWithBearerTimeout`'s error
/// strings never include the bearer token (format is `"POST <url> failed:
/// <message>"`), so truncation here is purely a size bound, not a redaction.
pub val maxErrorLen: Int = 500

func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

/// Parse the stored digit-string `attempts` column back into an `Int`,
/// ignoring any non-digit character (defensive; the column is always
/// machine-written digits, starting at `"0"`).
pub func parseAttemptsCount(s: in String): Int {
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d >= 0 {
      n = n * 10 + d
    }
    i = i + 1
  }
  return n
}

func hexNibble(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  if c == "a" or c == "A" {
    return 10
  }
  if c == "b" or c == "B" {
    return 11
  }
  if c == "c" or c == "C" {
    return 12
  }
  if c == "d" or c == "D" {
    return 13
  }
  if c == "e" or c == "E" {
    return 14
  }
  if c == "f" or c == "F" {
    return 15
  }
  return 0
}

/// Deterministic pseudo-jitter in `[0, range]`, derived from `seed` (in
/// practice the outbox row's own id, a UUID) and `attempts` — NOT real
/// randomness. Two rows retrying at the same `attempts` count get different
/// (but reproducible) jitter because their ids differ, spreading a burst of
/// simultaneously-failing rows across the backoff window instead of all
/// waking at exactly the same millisecond; a test that fixes `seed` and
/// `attempts` gets a fixed answer. Every intermediate `acc` is kept below
/// `modBound` (chosen so `modBound * 31` fits well inside `Int32`), so this
/// never overflows regardless of `seed`'s length.
func seedJitter(seed: in String, attempts: in Int, range: in Int): Int {
  if range <= 0 {
    return 0
  }
  val modBound = 1000003
  var acc = (attempts * 7 + 13) % modBound
  var i = 0
  while i < seed.length {
    val v = hexNibble(seed.substring(i, 1))
    acc = (acc * 31 + v) % modBound
    i = i + 1
  }
  if acc < 0 {
    acc = acc + modBound
  }
  return acc % (range + 1)
}

/// The retry delay (in milliseconds) for a row about to make its `attempts`-th
/// attempt (1-indexed: `attempts == 1` is the delay before the FIRST retry,
/// i.e. after the initial synchronous attempt already failed once). Doubles
/// per attempt from `baseDelayMillis`, capped at `maxDelayMillis`, then
/// "equal jitter" (half the exponential value, guaranteed, plus a
/// deterministic random top-up of up to the other half —
/// https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/'s
/// "Equal Jitter", chosen over "Full Jitter" specifically so the result never
/// collapses to a near-zero delay): the returned value is always in
/// `[ceiling/2, ceiling]` where `ceiling = min(baseDelayMillis *
/// 2^(attempts-1), maxDelayMillis)`. Critically, jitter is computed from
/// `ceiling` (which saturates at `maxDelayMillis`), not added on top of an
/// already-at-cap value and then re-clamped — so even once many attempts have
/// pushed `ceiling` to the cap, retries still spread across the full
/// `[maxDelayMillis/2, maxDelayMillis]` window instead of every capped row
/// converging on the exact same instant.
///
/// `attempts <= 0` is treated as `1` (never a zero or negative delay).
pub func backoffDelayMillis(attempts: in Int, seed: in String): Int {
  val exp = if attempts < 1 { 0 } else if attempts > 11 { 11 } else { attempts - 1 }
  var ceiling = baseDelayMillis
  var i = 0
  while i < exp {
    ceiling = ceiling * 2
    if ceiling > maxDelayMillis {
      ceiling = maxDelayMillis
    }
    i = i + 1
  }
  val half = ceiling / 2
  val jitter = seedJitter(seed, attempts, ceiling - half)
  return half + jitter
}

/// Whether a row that has now failed `attempts` times has exhausted its
/// retry budget and should be given up on (marked terminal) rather than
/// scheduled for another retry.
pub func isTerminal(attempts: in Int, maxAttempts: in Int): Bool {
  return attempts >= maxAttempts
}

/// Bound `raw` to `maxLen` characters, appending a marker when truncated so
/// a stored `last_error` never silently looks complete when it isn't.
pub func truncateError(raw: in String, maxLen: in Int): String {
  if raw.length <= maxLen {
    return raw
  }
  return raw.substring(0, maxLen) + "...(truncated)"
}

/// The `last_error` stored on a row that has just been given up on —
/// distinguishable at a glance (and by a `.contains("TERMINAL")` check) from
/// an ordinary retryable failure.
pub func terminalErrorMessage(raw: in String): String {
  return "TERMINAL (max attempts reached): " + truncateError(raw, maxErrorLen)
}

// True when `a > b`, treating both as non-negative decimal-digit strings
// with no leading zeros (always true of an epoch-millis value or
// `terminalSentinelMillis`): a longer string is always the larger number,
// and equal-length strings compare position-by-position. Deliberately hand-
// rolled rather than a `<`/`<=` operator on `String` — this codebase has no
// precedent anywhere of comparing two `String`s with a relational operator
// (only `==`/`!=`, plus the explicit `System.String.CompareOrdinal` binding
// `CloudAgents.Text` uses for ordinal character comparison), so this avoids
// relying on unverified String-ordering support in the toolchain.
func isGreaterDigitString(a: in String, b: in String): Bool {
  if a.length != b.length {
    return a.length > b.length
  }
  var i = 0
  while i < a.length {
    val ca = a.substring(i, 1)
    val cb = b.substring(i, 1)
    if ca != cb {
      return digitValue(ca) > digitValue(cb)
    }
    i = i + 1
  }
  return false
}

/// Whether a row whose `next_attempt_at` is `nextAttemptAt` is actually due
/// at `nowMillis` — i.e. genuinely due for a delivery attempt, not merely
/// "not yet delivered" (#1051: `enqueueAndAttemptDelivery` re-enqueuing an
/// already-queued, currently-mid-backoff row must NOT jump the Equal-Jitter
/// schedule this package computes). Both arguments are epoch-millis digit
/// strings (`CloudAgents.Repository.nowMillis()` / a stored `next_attempt_at`
/// column, or `terminalSentinelMillis`), so this needs no `Long` arithmetic —
/// see the module doc's `Long`-avoidance rationale.
pub func isDueNow(nextAttemptAt: in String, nowMillis: in String): Bool {
  return not isGreaterDigitString(nextAttemptAt, nowMillis)
}
