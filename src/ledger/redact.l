//! CloudAgents.Ledger.Redact — scrubs secrets out of ledger text before it is
//! stored (docs/claude-session-import.md §12). Imported findings quote and
//! paraphrase transcripts, and transcripts carry pasted tokens, environment
//! values and command output, so every free-text field is run through
//! `redactText` on ingest. A match is replaced with `[redacted:<kind>]`.
//!
//! The rules, in the order they apply at each word boundary:
//!   - PEM private key blocks (a pre-pass, since they span lines);
//!   - URL user info (`scheme://user:pass@host`, also a pre-pass);
//!   - prefixed tokens: GitHub (`ghp_` and friends, `github_pat_`), Anthropic
//!     (`sk-ant-`) and other `sk-` keys, this system's import tokens (`cai_`),
//!     AWS access key ids (`AKIA`/`ASIA` + 16);
//!   - `Bearer`/`Basic` credentials;
//!   - the value of a secret-named key (`API_KEY=…`, `"password": "…"`);
//!   - long high-entropy runs (32+ base64 characters mixing upper case, lower
//!     case and digits), except pure hex, `session_`/`cse_` ids and anything
//!     touching `/`. That rule is skipped for file paths (`redactPath`).
//! Pure, and idempotent: redacting redacted text changes nothing.
package CloudAgents.Ledger.Redact

import Std.Core

val upperChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

val lowerChars = "abcdefghijklmnopqrstuvwxyz"

val digitChars = "0123456789"

val hexChars = "0123456789abcdefABCDEF"

val marker = "[redacted:"

/// `s` with every secret replaced by a `[redacted:<kind>]` marker.
pub func redactText(s: in String): String {
  return redactWith(s, true)
}

/// `redactText` for a file path: the high-entropy rule is skipped, since long
/// mixed-case path segments are common and not secret. Every other rule still
/// applies.
pub func redactPath(s: in String): String {
  return redactWith(s, false)
}

func redactWith(s: in String, entropy: in Bool): String {
  return redactTokens(redactUrlCredentials(redactPem(s)), entropy)
}

@externInstance
@externTarget("System.String.ToLowerInvariant")
func lowerAscii(s: in String): String = ()

// ── Character classes ─────────────────────────────────────────────────────────
func charAt(s: in String, i: in Int): String {
  return s.substring(i, 1)
}

func isUpper(c: in String): Bool {
  return upperChars.contains(c)
}

func isLower(c: in String): Bool {
  return lowerChars.contains(c)
}

func isDigit(c: in String): Bool {
  return digitChars.contains(c)
}

func isAlnum(c: in String): Bool {
  return isUpper(c) or isLower(c) or isDigit(c)
}

/// Characters a key name or prefixed token is made of.
func isWordChar(c: in String): Bool {
  return isAlnum(c) or c == "_" or c == "-"
}

/// Characters a high-entropy run is made of: base64 (standard and URL-safe)
/// without `/`, so a path splits into segments.
func isRunChar(c: in String): Bool {
  return isWordChar(c) or c == "+" or c == "="
}

func isSpace(c: in String): Bool {
  return c == " " or c == "\t" or c == "\n" or c == "\r"
}

/// The end of a run of word characters starting at `from`.
func scanWord(s: in String, from: in Int): Int {
  var j = from
  while j < s.length.toInt() and isWordChar(charAt(s, j)) {
    j = j + 1
  }
  return j
}

func scanRun(s: in String, from: in Int): Int {
  var j = from
  while j < s.length.toInt() and isRunChar(charAt(s, j)) {
    j = j + 1
  }
  return j
}

func skipSpaces(s: in String, from: in Int): Int {
  var j = from
  while j < s.length.toInt() and (charAt(s, j) == " " or charAt(s, j) == "\t") {
    j = j + 1
  }
  return j
}

/// The first index of `sub` in `s` at or after `from`, or -1.
func indexFrom(s: in String, sub: in String, from: in Int): Int {
  val n = s.length.toInt()
  val m = sub.length.toInt()
  var i = from
  while i + m <= n {
    if s.substring(i, m) == sub {
      return i
    }
    i = i + 1
  }
  return -1
}

func startsAt(s: in String, i: in Int, prefix: in String): Bool {
  val m = prefix.length.toInt()
  return i >= 0 and i + m <= s.length.toInt() and s.substring(i, m) == prefix
}

// ── Pre-passes ───────────────────────────────────────────────────────────────
/// PEM private key blocks, BEGIN line through END line.
func redactPem(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length.toInt() {
    val begin = indexFrom(s, "-----BEGIN ", i)
    if begin < 0 {
      acc = acc + s.substring(i, s.length.toInt() - i)
      i = s.length.toInt()
    } else {
      val headerEnd = indexFrom(s, "-----", begin + 11)
      val header = if headerEnd < 0 then "" else s.substring(begin, headerEnd - begin)
      val endLine = if headerEnd < 0 then -1 else indexFrom(s, "-----END ", headerEnd + 5)
      val endClose = if endLine < 0 then -1 else indexFrom(s, "-----", endLine + 9)
      if header.contains("PRIVATE KEY") and endClose >= 0 {
        acc = acc + s.substring(i, begin - i) + marker + "private-key]"
        i = endClose + 5
      } else {
        acc = acc + s.substring(i, begin + 11 - i)
        i = begin + 11
      }
    }
  }
  return acc
}

/// `scheme://user:pass@host`: the user info, when it carries a password.
func redactUrlCredentials(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length.toInt() {
    val sep = indexFrom(s, "://", i)
    if sep < 0 {
      acc = acc + s.substring(i, s.length.toInt() - i)
      i = s.length.toInt()
    } else {
      val start = sep + 3
      var j = start
      var at = -1
      while j < s.length.toInt() and at < 0 and not isSpace(charAt(s, j)) and charAt(s, j) != "/" {
        if charAt(s, j) == "@" {
          at = j
        }
        j = j + 1
      }
      val userInfo = if at < 0 then "" else s.substring(start, at - start)
      if at > start and userInfo.contains(":") {
        acc = acc + s.substring(i, start - i) + marker + "credentials]"
        i = at
      } else {
        acc = acc + s.substring(i, start - i)
        i = start
      }
    }
  }
  return acc
}

// ── Word rules ───────────────────────────────────────────────────────────────
/// A prefixed token kind and the fewest characters it needs after the prefix.
record Prefix {
  pub text: String
  pub kind: String
  pub minRest: Int
}

func prefixes(): slice[Prefix] {
  return [
    Prefix(text = "github_pat_", kind = "github-token", minRest = 20),
    Prefix(text = "ghp_", kind = "github-token", minRest = 20),
    Prefix(text = "gho_", kind = "github-token", minRest = 20),
    Prefix(text = "ghu_", kind = "github-token", minRest = 20),
    Prefix(text = "ghs_", kind = "github-token", minRest = 20),
    Prefix(text = "ghr_", kind = "github-token", minRest = 20),
    Prefix(text = "sk-ant-", kind = "anthropic-key", minRest = 20),
    Prefix(text = "sk-", kind = "api-key", minRest = 20),
    Prefix(text = "cai_", kind = "import-token", minRest = 16)
  ]
}

/// A word-boundary match: the text it replaces up to `stop` (exclusive), and what replaces it.
record Match {
  pub stop: Int
  pub replacement: String
}

func noMatch(): Match {
  return Match(stop = -1, replacement = "")
}

func prefixedToken(s: in String, i: in Int): Match {
  val ps = prefixes()
  var k = 0
  while k < ps.length.toInt() {
    val p = ps[k]
    if startsAt(s, i, p.text) {
      val stop = scanWord(s, i + p.text.length.toInt())
      if stop - i - p.text.length.toInt() >= p.minRest {
        return Match(stop = stop, replacement = marker + p.kind + "]")
      }
      return noMatch()
    }
    k = k + 1
  }
  return noMatch()
}

func awsKeyId(s: in String, i: in Int): Match {
  if not (startsAt(s, i, "AKIA") or startsAt(s, i, "ASIA")) {
    return noMatch()
  }
  var j = i + 4
  while j < s.length.toInt() and (isUpper(charAt(s, j)) or isDigit(charAt(s, j))) {
    j = j + 1
  }
  val boundary = j >= s.length.toInt() or not isWordChar(charAt(s, j))
  if j - i == 20 and boundary {
    return Match(stop = j, replacement = marker + "aws-key-id]")
  }
  return noMatch()
}

/// `Bearer xyz` / `Basic xyz`: the scheme is kept, the credential replaced.
func authScheme(s: in String, i: in Int): Match {
  val lower = lowerAscii(s)
  var scheme = ""
  if startsAt(lower, i, "bearer ") {
    scheme = s.substring(i, 6)
  } else if startsAt(lower, i, "basic ") {
    scheme = s.substring(i, 5)
  } else {
    return noMatch()
  }
  val start = skipSpaces(s, i + scheme.length.toInt())
  if startsAt(s, start, marker) {
    return noMatch()
  }
  var j = start
  while j < s.length.toInt() and (isRunChar(charAt(s, j)) or charAt(s, j) == "." or charAt(s, j) == "/" or charAt(s, j) == "~") {
    j = j + 1
  }
  if j - start >= 8 {
    return Match(stop = j, replacement = scheme + " " + marker + "credential]")
  }
  return noMatch()
}

/// Whether a key name says its value is secret. Matching on the name's ending
/// keeps `max_tokens` and `tokens_used` out while catching `GITHUB_TOKEN`,
/// `apiToken` and `client_secret`.
pub func isSecretKeyName(name: in String): Bool {
  val n = lowerAscii(name)
  val endings = ["token", "secret", "password", "passwd", "pwd", "apikey", "api_key", "api-key", "private_key", "access_key", "authorization", "credential", "credentials"]
  var i = 0
  while i < endings.length.toInt() {
    if n.endsWith(endings[i]) {
      return true
    }
    i = i + 1
  }
  return false
}

func isPlaceholderValue(v: in String): Bool {
  val l = lowerAscii(v)
  return l == "true" or l == "false" or l == "null" or l == "none" or l == "undefined" or l == "bearer" or l == "basic" or v.startsWith(marker)
}

/// `KEY=value`, `key: value`, `"key": "value"`: the value of a secret-named key.
func secretAssignment(s: in String, i: in Int): Match {
  val nameEnd = scanWord(s, i)
  if nameEnd == i or not isSecretKeyName(s.substring(i, nameEnd - i)) {
    return noMatch()
  }
  var p = nameEnd
  if p < s.length.toInt() and (charAt(s, p) == "\"" or charAt(s, p) == "'") {
    p = p + 1
  }
  p = skipSpaces(s, p)
  if p >= s.length.toInt() or not (charAt(s, p) == "=" or charAt(s, p) == ":") {
    return noMatch()
  }
  p = skipSpaces(s, p + 1)
  if p >= s.length.toInt() {
    return noMatch()
  }
  val q = charAt(s, p)
  var start = p
  var stop = p
  if q == "\"" or q == "'" {
    start = p + 1
    stop = start
    while stop < s.length.toInt() and charAt(s, stop) != q {
      stop = stop + 1
    }
  } else {
    while stop < s.length.toInt() and not isSpace(charAt(s, stop)) and not ",;}&)".contains(charAt(s, stop)) {
      stop = stop + 1
    }
  }
  val value = s.substring(start, stop - start)
  if value.length.toInt() < 4 or isPlaceholderValue(value) {
    return noMatch()
  }
  return Match(stop = stop, replacement = s.substring(i, start - i) + marker + "secret]")
}

func isAllHex(run: in String): Bool {
  var i = 0
  while i < run.length.toInt() {
    val c = charAt(run, i)
    if not (hexChars.contains(c) or c == "-") {
      return false
    }
    i = i + 1
  }
  return true
}

/// A long run mixing upper case, lower case and digits, outside a path.
func highEntropy(s: in String, i: in Int): Match {
  val stop = scanRun(s, i)
  if stop - i < 32 {
    return noMatch()
  }
  val touchesSlash = (i > 0 and charAt(s, i - 1) == "/") or (stop < s.length.toInt() and charAt(s, stop) == "/")
  val run = s.substring(i, stop - i)
  if touchesSlash or isAllHex(run) or run.startsWith("session_") or run.startsWith("cse_") {
    return noMatch()
  }
  var upper = false
  var lower = false
  var digit = false
  var k = 0
  while k < run.length.toInt() {
    val c = charAt(run, k)
    upper = upper or isUpper(c)
    lower = lower or isLower(c)
    digit = digit or isDigit(c)
    k = k + 1
  }
  if upper and lower and digit {
    return Match(stop = stop, replacement = marker + "high-entropy]")
  }
  return noMatch()
}

func firstMatch(s: in String, i: in Int, entropy: in Bool): Match {
  val pre = prefixedToken(s, i)
  if pre.stop >= 0 {
    return pre
  }
  val aws = awsKeyId(s, i)
  if aws.stop >= 0 {
    return aws
  }
  val auth = authScheme(s, i)
  if auth.stop >= 0 {
    return auth
  }
  val assign = secretAssignment(s, i)
  if assign.stop >= 0 {
    return assign
  }
  if entropy {
    return highEntropy(s, i)
  }
  return noMatch()
}

func redactTokens(s: in String, entropy: in Bool): String {
  var acc = ""
  var i = 0
  val n = s.length.toInt()
  while i < n {
    val boundary = i == 0 or not isRunChar(charAt(s, i - 1))
    if boundary and isRunChar(charAt(s, i)) and not startsAt(s, i - 1, marker) {
      val m = firstMatch(s, i, entropy)
      if m.stop >= 0 {
        acc = acc + m.replacement
        i = m.stop
      } else {
        acc = acc + charAt(s, i)
        i = i + 1
      }
    } else {
      acc = acc + charAt(s, i)
      i = i + 1
    }
  }
  return acc
}
