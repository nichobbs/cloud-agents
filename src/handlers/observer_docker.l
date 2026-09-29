//! CloudAgents.ObserverDocker — the container side of the session-ledger
//! observer (docs/session-ledger.md §10): runs an observer pass as a normal
//! blocking session run, and reads an observed workspace's diff through the
//! read-only inspect container. Kept apart from CloudAgents.ObserverHandlers
//! so the pass logic there can be tested against a fake runner.
package CloudAgents.ObserverDocker

import Std.Core
import CloudAgents.Docker
import CloudAgents.Workspace
import CloudAgents.ObserverHandlers

pub record DockerObserverRunner {
  pub unused: String
}

pub func dockerObserverRunner(): DockerObserverRunner {
  return DockerObserverRunner(unused = "")
}

impl ObserverRunner for DockerObserverRunner {
  func runObserver(
    observerSessionId: in String,
    repoUrl: in String,
    branch: in String,
    harness: in String,
    model: in String,
    profileId: in String,
    userId: in String,
    prompt: in String,
  ): Result[String, String] {
    // The container itself narrows the profile to the observer's surface
    // (CloudAgents.Docker.createRunnerContainer, keyed on the session being
    // an observer), so the observed profile id only supplies credentials and
    // the network policy.
    return CloudAgents.Docker.runSessionMessageBlocking(
      repoUrl,
      branch,
      prompt,
      observerSessionId,
      harness,
      model,
      observerSessionId,
      profileId,
      userId,
      ""
    )
  }

  func workspaceDiff(sessionId: in String, harness: in String, userId: in String): Result[String, String] {
    val logs = CloudAgents.Docker.runInspectContainer(sessionId, harness, userId, "diff", "")?
    val outcome = CloudAgents.Workspace.parseInspectLog(logs)
    if not outcome.ok {
      return Err(error = "the inspect container could not read the workspace: " + outcome.err)
    }
    // Section 2 is the raw unified `git diff HEAD`.
    if outcome.sections.length.toInt() >= 3 {
      return Ok(value = outcome.sections[2])
    }
    return Ok(value = "")
  }
}
