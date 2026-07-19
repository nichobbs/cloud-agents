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
