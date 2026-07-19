//! tests/fakes.l — CloudAgents.Shim.TestFakes: an in-memory
//! CallbackTransport fake, shared by tests/callbacks_client_tests.l and
//! tests/tools_tests.l.
//!
//! Registered under [project.packages] in lyric.toml (not [project.tests])
//! purely so both `@test_module` files can `import` it by package name —
//! it carries no `test "..." { }` blocks of its own and is never run
//! directly by `lyric test`.
//!
//! Poll responses are scripted as an ordered list per endpoint: each call
//! returns the next entry, clamped to the last entry once the list is
//! exhausted (so a single-element list — e.g. always "pending" — behaves
//! as "repeat forever", exactly what a client-side-timeout test needs).
//!
//! Each one-shot outcome (create*/reportProgress) is scripted as an
//! ok/body/error triple rather than a single `Result[String, String]`
//! field: a self-hosted MSIL codegen bug (confirmed by direct bisection —
//! not documented upstream under this exact shape, but the same family as
//! lyric-lang's documented "plain record's concrete generic field" `Option`
//! bug, docs/10-bootstrap-progress.md) makes reading a `Result[T, E]`
//! value back out of a record field and matching on it panic
//! "match not exhaustive" at runtime, even though constructing the exact
//! same `Ok`/`Err` value fresh inside the method (as `pollPermission`/
//! `pollQuestion` below do) works fine. Splitting the scripted outcome into
//! a `Bool` + plain `String` fields and reconstructing `Ok`/`Err` fresh on
//! every call sidesteps the bug entirely.
package CloudAgents.Shim.TestFakes

import Std.Core
import Std.Collections
import CloudAgents.Shim.Transport

pub record FakeTransport {
  pub var createPermissionOk: Bool
  pub var createPermissionBody: String
  pub var createPermissionError: String

  pub var pollPermissionBodies: List[String]
  pub var pollPermissionCallCount: Int

  pub var createQuestionOk: Bool
  pub var createQuestionBody: String
  pub var createQuestionError: String

  pub var pollQuestionBodies: List[String]
  pub var pollQuestionCallCount: Int

  pub var reportProgressOk: Bool
  pub var reportProgressError: String
  pub var reportProgressCallCount: Int
}

/// A ready-to-use fake with sensible not-configured-yet defaults: creating
/// either kind of request fails outright, and progress reports succeed.
/// Override the fields a given test actually exercises.
pub func newFakeTransport(): FakeTransport {
  FakeTransport(
    createPermissionOk = false,
    createPermissionBody = "",
    createPermissionError = "FakeTransport: createPermission not configured",
    pollPermissionBodies = newList(),
    pollPermissionCallCount = 0,
    createQuestionOk = false,
    createQuestionBody = "",
    createQuestionError = "FakeTransport: createQuestion not configured",
    pollQuestionBodies = newList(),
    pollQuestionCallCount = 0,
    reportProgressOk = true,
    reportProgressError = "",
    reportProgressCallCount = 0
  )
}

func nextScripted(bodies: in List[String], callCount: in Int): String {
  val idx = if callCount < bodies.count { callCount } else { bodies.count - 1 }
  return bodies[idx]
}

impl CallbackTransport for FakeTransport {
  func createPermission(toolName: in String, inputJson: in String): Result[String, String] {
    if self.createPermissionOk {
      Ok(value = self.createPermissionBody)
    } else {
      Err(error = self.createPermissionError)
    }
  }

  func pollPermission(requestId: in String): Result[String, String] {
    val body = nextScripted(self.pollPermissionBodies, self.pollPermissionCallCount)
    self.pollPermissionCallCount = self.pollPermissionCallCount + 1
    Ok(value = body)
  }

  func createQuestion(question: in String, optionsJson: in String): Result[String, String] {
    if self.createQuestionOk {
      Ok(value = self.createQuestionBody)
    } else {
      Err(error = self.createQuestionError)
    }
  }

  func pollQuestion(requestId: in String): Result[String, String] {
    val body = nextScripted(self.pollQuestionBodies, self.pollQuestionCallCount)
    self.pollQuestionCallCount = self.pollQuestionCallCount + 1
    Ok(value = body)
  }

  func reportProgress(summary: in String, percentComplete: in String): Result[Unit, String] {
    self.reportProgressCallCount = self.reportProgressCallCount + 1
    if self.reportProgressOk {
      Ok(value = ())
    } else {
      Err(error = self.reportProgressError)
    }
  }
}
