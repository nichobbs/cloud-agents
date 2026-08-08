//! Workspace inspector endpoints: a read-only look at a session's /workspace
//! volume (what changed, what files exist, one file's content) via
//! short-lived, credential-free, network-isolated inspect containers
//! (CloudAgents.Docker.runInspectContainer). All the parsing/validation/JSON
//! logic lives in the pure CloudAgents.Workspace package so it stays
//! unit-testable — this package imports the async CloudAgents.Docker package
//! and therefore can't be reached from a @test_module at all
//! (docs/lyric/gotchas.md), so it is kept to thin orchestration only.
package CloudAgents.WorkspaceHandlers

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Docker
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Workspace

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Owner-scoped session lookup returning the session's harness (which picks
/// the inspect image). 404 both when the session doesn't exist and when it
/// belongs to someone else — getSession is already owner-scoped by
/// CloudAgents.Auth.currentUserId(), the same non-leaking shape as
/// CloudAgents.Callbacks/Highlights' requireOwnedSession.
func requireOwnedSessionHarness(sessionId: in String): Result[String, Web.ApiError] {
  match CloudAgents.SessionStore.getSession(sessionId) {
    case Ok(Some(s)) -> return Ok(value = s.harness)
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

/// 409 until the session has at least one recorded run: the workspace volume
/// auto-creates on bind, so inspecting a never-run session would "succeed"
/// against an EMPTY volume — indistinguishable from a real empty diff. The
/// runs table (one row per claimed run, recorded at claim time) is the
/// cleanest existing signal that a runner container has actually mounted and
/// populated the volume.
func requireWorkspaceInitialized(sessionId: in String): Result[Unit, Web.ApiError] {
  match CloudAgents.Repository.listRuns(sessionId, CloudAgents.Auth.currentUserId()) {
    case Ok(runs) -> {
      if runs.length == 0 {
        return Err(Web.conflict("workspace not initialized yet"))
      }
      return Ok(value = ())
    }
    case Err(e) -> return Err(dbError(e))
  }
}

/// Map an entrypoint-reported inspect failure (the text after
/// CLOUD_AGENTS_INSPECT_ERR) to an API error. "no workspace" (volume exists
/// but nothing was ever cloned — e.g. every recorded run failed before its
/// clone) maps to the same 409 as the never-ran guard so the frontend shows
/// one consistent "no workspace yet" state; an empty err means neither
/// protocol marker was found (the container never reached the inspect
/// block), which is an infrastructure failure.
func inspectError(err: in String): Web.ApiError {
  if err.startsWith("no workspace") {
    return Web.conflict("workspace not initialized yet")
  }
  if err.length == 0 {
    return Web.internalError("workspace inspect produced no recognizable output")
  }
  return Web.internalError("workspace inspect failed: " + err)
}

/// The section at `i`, or "" when the entrypoint printed fewer sections.
func sectionAt(outcome: in CloudAgents.Workspace.InspectOutcome, i: in Int): String {
  if i < outcome.sections.length.toInt() {
    return outcome.sections[i]
  }
  return ""
}

/// Ownership + initialization guards, then one inspect-container run, its
/// logs parsed into the marker protocol. `userId` is captured here on the
/// request thread and passed explicitly into the Docker layer (the async
/// body runs on a worker thread where the thread-local identity does not
/// flow — see createRunnerContainer's doc comment).
func runInspect(sessionId: in String, mode: in String, path: in String): Result[CloudAgents.Workspace.InspectOutcome, Web.ApiError] {
  val harness = requireOwnedSessionHarness(sessionId)?
  requireWorkspaceInitialized(sessionId)?
  val userId = CloudAgents.Auth.currentUserId()
  match CloudAgents.Docker.runInspectContainer(sessionId, harness, userId, mode, path) {
    case Ok(logs) -> return Ok(value = CloudAgents.Workspace.parseInspectLog(logs))
    case Err(msg) -> return Err(Web.internalError("workspace inspect failed: " + msg))
  }
}

/// GET /api/sessions/{id}/workspace/diff — porcelain status + numstat +
/// unified patch from one diff-mode inspect run, as hand-built JSON
/// (CloudAgents.Workspace.diffJson).
pub func getWorkspaceDiffHandler(id: in String): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val outcome = runInspect(id, "diff", "")?
  if not outcome.ok {
    return Err(inspectError(outcome.err))
  }
  if outcome.sections.length.toInt() < 3 {
    return Err(Web.internalError("workspace inspect output was missing sections"))
  }
  val files = CloudAgents.Workspace.diffFilesOf(
    CloudAgents.Workspace.parsePorcelain(sectionAt(outcome, 0)),
    CloudAgents.Workspace.parseNumstat(sectionAt(outcome, 1))
  )
  return Ok(value = CloudAgents.Workspace.diffJson(files, sectionAt(outcome, 2)))
}

/// GET /api/sessions/{id}/workspace/files — the tracked+untracked file list
/// (git ls-files, capped at 5000 entries by the entrypoint's `head`).
pub func listWorkspaceFilesHandler(id: in String): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val outcome = runInspect(id, "tree", "")?
  if not outcome.ok {
    return Err(inspectError(outcome.err))
  }
  val paths = CloudAgents.Workspace.nonEmptyLines(sectionAt(outcome, 0))
  return Ok(
    value = CloudAgents.Workspace.fileListJson(paths, CloudAgents.Workspace.treeTruncated(paths.length.toInt()))
  )
}

/// GET /api/sessions/{id}/workspace/file?path=... — one file's byte size and
/// its first 1 MiB of content, base64-encoded. 400 on an invalid path
/// (validated BEFORE any container is spawned), 404 when the entrypoint
/// reported the path absent.
pub func getWorkspaceFileHandler(id: in String, path: in String): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if not CloudAgents.Workspace.validInspectPath(path) {
    return Err(Web.badRequest("invalid path"))
  }
  val outcome = runInspect(id, "file", path)?
  if not outcome.ok {
    if outcome.err.startsWith("not found") {
      return Err(Web.notFound("file not found in workspace"))
    }
    return Err(inspectError(outcome.err))
  }
  if outcome.sections.length.toInt() < 2 {
    return Err(Web.internalError("workspace inspect output was missing sections"))
  }
  val size = CloudAgents.Workspace.parseSizeLine(sectionAt(outcome, 0))
  if size.length == 0 {
    return Err(Web.internalError("workspace inspect returned an unreadable file size"))
  }
  val contentBase64 = CloudAgents.Workspace.joinBase64(sectionAt(outcome, 1))
  return Ok(
    value = CloudAgents.Workspace.fileContentJson(path, contentBase64, size, CloudAgents.Workspace.sizeExceedsCap(size))
  )
}
