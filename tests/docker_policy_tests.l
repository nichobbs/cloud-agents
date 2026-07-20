@test_module
package CloudAgents.DockerPolicyTests

import Std.Core
import Std.Testing
import CloudAgents.DockerPolicy

test "hasExceededRunTimeout is false at and under the cap, true once strictly over it (#67/#481)" {
  val startMs = 1_000_000.toLong()
  val timeoutMs = 1_800_000.toLong() // 30 minutes, matching streamSessionMessage's runTimeoutMs
  assertFalse(
    hasExceededRunTimeout(startMs, startMs, timeoutMs),
    "elapsed 0 is not exceeded"
  )
  assertFalse(
    hasExceededRunTimeout(startMs + timeoutMs, startMs, timeoutMs),
    "elapsed exactly equal to the cap is NOT exceeded (strict >, matching streamSessionMessage)"
  )
  assertTrue(
    hasExceededRunTimeout(startMs + timeoutMs + 1.toLong(), startMs, timeoutMs),
    "elapsed one millisecond over the cap is exceeded"
  )
  assertTrue(
    hasExceededRunTimeout(startMs + (timeoutMs * 2.toLong()), startMs, timeoutMs),
    "elapsed well past the cap is exceeded"
  )
}

test "shouldRetryContainerWait is bounded by both an attempt cap and a wall-clock deadline (#56)" {
  val now = 1_000_000.toLong()
  val deadline = 2_000_000.toLong() // now is well before the deadline in these cases

  // Attempts and time both remain: retry.
  assertTrue(
    shouldRetryContainerWait(1, 20, now, deadline),
    "a failure with attempts and time left is retried"
  )

  // The attempt cap is a hard stop independent of the wall-clock deadline —
  // this is what keeps an instantly-and-repeatedly-failing call (e.g. the
  // daemon is simply unreachable, or the container genuinely doesn't exist)
  // from spinning for the whole 30-minute window with no delay between
  // attempts.
  assertFalse(
    shouldRetryContainerWait(20, 20, now, deadline),
    "attempts exhausted (attempts == maxAttempts) stops retrying even with time left"
  )
  assertFalse(
    shouldRetryContainerWait(25, 20, now, deadline),
    "attempts already past maxAttempts stops retrying"
  )
  assertTrue(
    shouldRetryContainerWait(19, 20, now, deadline),
    "one attempt remaining (19 < 20) still retries"
  )

  // The wall-clock deadline is the other hard stop, independent of attempts
  // remaining — matches the 30-minute cap the rest of the run enforces.
  assertFalse(
    shouldRetryContainerWait(1, 20, deadline, deadline),
    "now == deadline stops retrying even with attempts left"
  )
  assertFalse(
    shouldRetryContainerWait(1, 20, deadline + 1.toLong(), deadline),
    "now past the deadline stops retrying"
  )
}
