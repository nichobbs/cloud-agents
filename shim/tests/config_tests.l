@test_module
package CloudAgents.Shim.ConfigTests

import Std.Core
import Std.Testing
import CloudAgents.Shim.Config

// Coverage for the CLOUD_AGENTS_CALLBACK_TIMEOUT_MS parsing/fallback policy
// (#527). CloudAgents.Callbacks.tryParseMillis is the host-side twin — these
// cases mirror the behavior both ends must share.
test "tryParseMillis parses a plain decimal run" {
  assertEqualInt(tryParseMillis("25000"), 25000, "plain decimal parses")
}

test "tryParseMillis parses zero" {
  assertEqualInt(tryParseMillis("0"), 0, "zero is a valid parse, distinct from failure")
}

test "tryParseMillis rejects the empty string" {
  assertEqualInt(tryParseMillis(""), -1, "empty input is a parse failure")
}

test "tryParseMillis rejects non-digit characters" {
  assertEqualInt(tryParseMillis("25s"), -1, "trailing unit suffix is rejected")
  assertEqualInt(tryParseMillis("-1"), -1, "sign character is rejected")
  assertEqualInt(tryParseMillis("2 5"), -1, "embedded space is rejected")
}

test "tryParseMillis rejects more than nine digits" {
  assertEqualInt(tryParseMillis("1234567890"), -1, "ten digits exceed the documented bound")
  assertEqualInt(tryParseMillis("999999999"), 999999999, "nine digits are the accepted maximum")
}

// 600000 is asserted as a literal rather than reading the cross-package
// `defaultTimeoutMs` pub val: cross-package pub val reads are the
// lyric-lang#6232/#6133 bug family this repo's gotchas doc catalogues.
test "timeoutFromRaw falls back to the default on empty input" {
  assertEqualInt(timeoutFromRaw(""), 600000, "unset env var means the 10-minute default")
}

test "timeoutFromRaw falls back to the default on garbage input" {
  assertEqualInt(timeoutFromRaw("soon"), 600000, "unparseable env var means the default, not a crash")
}

test "timeoutFromRaw honors a valid override" {
  assertEqualInt(timeoutFromRaw("120000"), 120000, "a parseable override wins over the default")
}

// ─── Phase 7 §7: per-profile tool enablement (docs/phase7-autonomy.md) ────────
//
// CloudAgents.Docker injects CLOUD_AGENTS_ENABLED_TOOLS as a comma-separated
// allowlist only for a 'selected'-mode profile; main.l wraps every addTool
// call in `if toolIsEnabled(enabledToolsCsv, "<name>")`. These cases mirror
// main.l's exact 13-tool set (the original 9, add_task/list_tasks/
// complete_task from the repo-scoped task list slice, and notify — #625)
// so a passing suite proves the real registration gate, not just the
// parsing helper in isolation.
val allShimToolNames: slice[String] = ["request_permission", "ask_user", "report_progress", "request_secret", "add_followup_task", "report_artifact", "remember", "recall", "forget", "add_task", "list_tasks", "complete_task", "notify"]

func enabledSubsetOf(csv: in String): slice[String] {
  var acc: slice[String] = []
  for name in allShimToolNames {
    if toolIsEnabled(csv, name) {
      acc = acc.append(name)
    }
  }
  return acc
}

test "toolIsEnabled registers every tool when the env var is empty (unchanged behaviour)" {
  assertEqualInt(enabledSubsetOf("").length.toInt(), 13, "empty CSV enables all 13 known tools")
}

test "toolIsEnabled restricts registration to a non-empty allowlist" {
  val enabled = enabledSubsetOf("remember,recall")
  assertEqualInt(enabled.length.toInt(), 2, "only the two listed tools are enabled")
  assertTrue(toolIsEnabled("remember,recall", "remember"), "remember is enabled")
  assertTrue(toolIsEnabled("remember,recall", "recall"), "recall is enabled")
  assertTrue(not toolIsEnabled("remember,recall", "forget"), "forget is NOT enabled")
  assertTrue(not toolIsEnabled("remember,recall", "request_permission"), "request_permission is NOT enabled")
}

test "toolIsEnabled matches a single-tool allowlist exactly" {
  assertTrue(toolIsEnabled("ask_user", "ask_user"), "single-entry CSV matches")
  assertTrue(not toolIsEnabled("ask_user", "ask_users"), "no partial/prefix match")
  assertTrue(not toolIsEnabled("ask_user", "sk_user"), "no partial/suffix match")
}
