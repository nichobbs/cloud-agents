@test_module
package CloudAgents.HighlightsTests

import Std.Core
import Std.Testing
import CloudAgents.Highlights

// ── buildChatRequestJson ─────────────────────────────────────────────────────
test "buildChatRequestJson embeds the model and escapes the agent output" {
  val body = buildChatRequestJson("big-pickle", "line one\nwith \"quotes\"")
  assertTrue(body.startsWith("{\"model\":\"big-pickle\""), "model field first: " + body.substring(0, 30))
  assertTrue(body.contains("\\n"), "newlines are JSON-escaped")
  assertTrue(body.contains("\\\"quotes\\\""), "quotes are JSON-escaped")
  assertTrue(body.contains("\"role\":\"user\""), "single user message")
}

// ── jsonStringValueOf ────────────────────────────────────────────────────────
test "jsonStringValueOf extracts and unescapes a chat completion's content" {
  val resp = "{\"id\":\"c1\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"discovery | found it | a \\\"quoted\\\" note\\nnone\"}}]}"
  val content = jsonStringValueOf(resp, "content")
  assertTrue(content.contains("a \"quoted\" note"), "escaped quotes resolve: " + content)
  assertTrue(content.contains("\n"), "\\n resolves to a real newline")
}

test "jsonStringValueOf handles \\u escapes and lone surrogates safely" {
  assertEqual(jsonStringValueOf("{\"content\":\"caf\\u00e9\"}", "content"), "café", "\\u00e9 decodes")
  val lone = jsonStringValueOf("{\"content\":\"x\\ud800y\"}", "content")
  assertTrue(lone.contains("x") and lone.contains("y"), "lone surrogate does not destroy the rest: " + lone)
}

test "jsonStringValueOf returns empty for a missing or non-string field" {
  assertEqual(jsonStringValueOf("{\"other\":\"x\"}", "content"), "", "missing key -> empty")
  assertEqual(jsonStringValueOf("{\"content\":{\"nested\":1}}", "content"), "", "non-string value -> empty")
  assertEqual(jsonStringValueOf("{\"content\":\"unterminated", "content"), "", "unterminated string -> empty")
}

// ── parseHighlightLines ──────────────────────────────────────────────────────
test "parseHighlightLines parses kind | title | detail lines and drops junk" {
  val items = parseHighlightLines(
    "discovery | flaky test found | retry masks a race in auth_tests\n" +
      "ISSUE | opened lyric-lang#123 | filed upstream for the codegen crash\n" +
      "- workaround | pinned v0.4.19 | avoids the append bug\n" +
      "not-a-kind | nope | dropped\n" +
      "just some prose the model added\n" +
      "incomplete | skipped e2e test\n" +
      "none"
  )
  assertEqualInt(items.length.toInt(), 4, "four valid items survive")
  assertEqual(items[0].kind, "discovery", "first kind")
  assertEqual(items[1].kind, "issue", "kind is case-normalized")
  assertTrue(items[1].title.contains("lyric-lang#123"), "issue title carries the reference")
  assertEqual(items[2].kind, "workaround", "leading bullet is stripped")
  assertEqual(items[3].kind, "incomplete", "two-field line parses with empty detail")
  assertEqual(items[3].detail, "", "missing detail is empty, not garbage")
}

test "parseHighlightLines returns nothing for 'none' or empty content" {
  assertEqualInt(parseHighlightLines("none").length.toInt(), 0, "'none' -> no items")
  assertEqualInt(parseHighlightLines("").length.toInt(), 0, "empty -> no items")
  assertEqualInt(parseHighlightLines("| no kind | x").length.toInt(), 0, "empty kind -> dropped")
}

test "parseHighlightLines caps runaway output at 20 items" {
  var content = ""
  var i = 0
  while i < 50 {
    content = content + "followup | item " + toString(i) + " | detail\n"
    i = i + 1
  }
  assertEqualInt(parseHighlightLines(content).length.toInt(), 20, "capped at maxItemsPerMessage")
}

// ── contentTail ──────────────────────────────────────────────────────────────
test "contentTail keeps short content whole and truncates long content from the front" {
  assertEqual(contentTail("short"), "short", "short content unchanged")
  var long = "x"
  while long.length < 20000 {
    long = long + long
  }
  val tail = contentTail(long)
  assertEqualInt(tail.length.toInt(), 16000, "long content truncated to the cap")
}

// ── kind allowlist ───────────────────────────────────────────────────────────
test "isValidHighlightKind accepts exactly the six kinds" {
  assertTrue(isValidHighlightKind("discovery"), "discovery")
  assertTrue(isValidHighlightKind("issue"), "issue")
  assertTrue(isValidHighlightKind("workaround"), "workaround")
  assertTrue(isValidHighlightKind("revert"), "revert")
  assertTrue(isValidHighlightKind("incomplete"), "incomplete")
  assertTrue(isValidHighlightKind("followup"), "followup")
  assertTrue(not isValidHighlightKind("progress"), "no extra kinds")
  assertTrue(not isValidHighlightKind(""), "empty is invalid")
}
