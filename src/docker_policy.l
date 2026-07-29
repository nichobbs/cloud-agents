//! Pure timeout/retry decision logic for the container run lifecycle
//! (#56/#67). This lives in its own package rather than CloudAgents.Docker
//! so it is unit-testable: invoking ANY function from the async
//! CloudAgents.Docker package via the @test_module harness throws "The
//! signature is incorrect." (a documented Lyric runtime limitation,
//! docs/lyric/gotchas.md), even for a pure leaf function — so a test can't
//! reach these while they live there. A test importing this pure package
//! hits no such limitation. Same rationale as CloudAgents.NetworkPolicy,
//! split out of CloudAgents.Docker for exactly this reason.
package CloudAgents.DockerPolicy

import Std.Core

/// Whether a run that started at `startMs` has exceeded `timeoutMs` as of
/// `nowMs`. Backs the 30-minute hard cap `streamSessionMessage` enforces
/// around the whole run (#481) — split out here so the boundary condition
/// (exactly at the cap does NOT count as exceeded; only strictly over it
/// does) has direct test coverage (#67) instead of only being exercised in
/// docker_manager.l's `CloudAgents.Docker` package, which the current
/// toolchain's @test_module harness cannot import from at all (see the
/// module doc comment above).
pub func hasExceededRunTimeout(nowMs: in Long, startMs: in Long, timeoutMs: in Long): Bool {
  return nowMs - startMs > timeoutMs
}

/// Whether `waitForContainer` should retry a failed Docker `/wait` call
/// rather than surface the failure immediately (#56).
///
/// Docker's `/wait` endpoint long-polls until the container process exits,
/// which can legitimately take up to the full 30-minute run cap — but the
/// HTTP client `Lyric.Docker`'s `waitContainer` sends through is entirely
/// out of this project's control: `makeDockerClient()` and friends take no
/// timeout parameter, and `DockerClient`'s `handle: Std.Http.HttpClient`
/// field lives on an opaque type with no public accessor (confirmed by
/// inspecting the published `Lyric.Docker` 0.4.31 package's own contract
/// metadata — there is no timeout-configuring function anywhere in its
/// public surface). If that client's own request timeout is shorter than 30
/// minutes (a bare .NET `HttpClient` commonly defaults to ~100 seconds), a
/// run that legitimately takes longer would fail the `/wait` call well
/// before the container actually finishes.
///
/// Since the client's timeout can't be configured from here, `waitContainer`
/// is retried instead: `/wait` is idempotent to re-call (an already-exited
/// container returns its exit code immediately; a still-running one just
/// resumes the long-poll), so one client-side timeout costs an extra round
/// trip rather than failing the run outright. Deliberately does NOT try to
/// distinguish "client-side timeout" from "real Docker error" by inspecting
/// `DockerError`'s fields — retrying is bounded two independent ways
/// instead, so a genuinely-doomed
/// call (e.g. "no such container") still costs only a handful of extra
/// round trips, not an unbounded spin:
/// - `attempts` has not reached `maxAttempts` — a hard cap independent of
///   wall-clock time, so a failure that fails instantly and repeatedly
///   (e.g. the daemon is simply unreachable) cannot spin for the full
///   30-minute window; it gives up after a bounded number of attempts.
/// - `nowMs` has not reached `deadlineMs` — the overall wall-clock budget,
///   matching the 30-minute cap the run's own hard timeout enforces.
pub func shouldRetryContainerWait(attempts: in Int, maxAttempts: in Int, nowMs: in Long, deadlineMs: in Long): Bool {
  if attempts >= maxAttempts {
    return false
  }
  return nowMs < deadlineMs
}

/// Appends a `DockerError`'s `details` (the raw Docker daemon HTTP response
/// body — e.g. `{"message":"No such image: opencode:base"}`) to its generic
/// `message` (a caller-supplied literal like "Create container failed"),
/// whenever `details` is non-empty. Split out here — rather than left inline
/// in `docker_manager.l`'s `createRunnerContainer` — for the same reason as
/// every other function in this file: `CloudAgents.Docker` is an async
/// package the `@test_module` harness cannot import from at all, so this
/// pure formatting step needs to live in a plain package to get any direct
/// test coverage.
pub func formatDockerError(message: in String, details: in String): String {
  if details.length > 0 {
    return message + ": " + details
  }
  return message
}
