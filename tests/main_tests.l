@test_module
package CloudAgents.MainTests

import Std.Core
import Std.Testing
import CloudAgents
import CloudAgents.Callbacks
import CloudAgents.Handlers
import CloudAgents.Prompts
import CloudAgents.Repository
import Web

test "unitResp maps Ok to 204 and Err to the error's own status (#351)" {
  assertEqualInt(unitResp(Ok(value = ())).status, 204, "Ok(Unit) -> 204 No Content")
  assertEqualInt(unitResp(Err(error = Web.badRequest("bad"))).status, 400, "Err(badRequest) -> 400")
  assertEqualInt(unitResp(Err(error = Web.notFound("missing"))).status, 404, "Err(notFound) -> 404")
}

test "jsonStringResp passes a pre-built JSON string through with a 200, maps Err to its status (#351)" {
  assertEqualInt(jsonStringResp(Ok(value = "{\"sessions\":[]}")).status, 200, "Ok(json) -> 200")
  assertEqualInt(jsonStringResp(Err(error = Web.internalError("db down"))).status, 500, "Err(internalError) -> 500")
}

test "badBody returns a 400 bad request (#351)" {
  assertEqualInt(badBody().status, 400, "badBody -> 400")
}

// ── The 15+ per-type *Resp helpers (#351) ────────────────────────────────────
//
// Each one is a hand-written Result[T, Web.ApiError] -> Web.Response mapping
// (Ok -> Web.json(200, v.toJson()), Err -> Web.errorResponse(e)); unlike
// unitResp/jsonStringResp above, none of these had ANY coverage before this
// suite, despite being exactly the "Result -> Response mappings" #351 calls
// out by name. Being hand-duplicated per type (Lyric has no generic
// Result[T,E]->Response helper), each is its own chance for a copy-paste slip
// (wrong status literal, swapped Ok/Err arm, forgotten .toJson()) — so each
// gets its own Ok/Err assertion rather than trusting the pattern once.
//
// Only .status is asserted, matching the two pre-existing tests above: a
// constructed Web.Request is required to read a Response's body via the
// handler pipeline, and Web.Response itself exposes no documented body
// accessor exercised elsewhere in this codebase, so this suite doesn't reach
// for one either.
test "session Resp helpers map Ok to 200 and Err to the error's own status (#351)" {
  assertEqualInt(createSessionResp(Ok(value = CreateSessionResponse(sessionId = "s1"))).status, 200, "createSessionResp Ok -> 200")
  assertEqualInt(createSessionResp(Err(error = Web.badRequest("bad"))).status, 400, "createSessionResp Err -> 400")

  assertEqualInt(sessionProfileResp(Ok(value = SessionProfileRef(profileId = "p1"))).status, 200, "sessionProfileResp Ok -> 200")
  assertEqualInt(sessionProfileResp(Err(error = Web.notFound("missing"))).status, 404, "sessionProfileResp Err -> 404")

  val noRuns: slice[Run] = []
  assertEqualInt(runListResp(Ok(value = RunList(runs = noRuns))).status, 200, "runListResp Ok -> 200")
  assertEqualInt(runListResp(Err(error = Web.internalError("db down"))).status, 500, "runListResp Err -> 500")

  val repo = SessionRepo(id = "r1", sessionId = "s1", repoUrl = "https://github.com/a/b", branch = "main", createdAt = "1")
  assertEqualInt(sessionRepoResp(Ok(value = repo)).status, 200, "sessionRepoResp Ok -> 200")
  assertEqualInt(sessionRepoResp(Err(error = Web.badRequest("bad"))).status, 400, "sessionRepoResp Err -> 400")

  val noRepos: slice[SessionRepo] = []
  assertEqualInt(sessionRepoListResp(Ok(value = SessionRepoList(repos = noRepos))).status, 200, "sessionRepoListResp Ok -> 200")
  assertEqualInt(sessionRepoListResp(Err(error = Web.notFound("missing"))).status, 404, "sessionRepoListResp Err -> 404")
}

// Split one-block-per-helper (#351 follow-up): the combined version failed
// CI with a bare "Common Language Runtime detected an invalid program" — the
// same class of cross-package JIT crash docs/lyric/gotchas.md catalogues
// several instances of (Web.Request construction, a Nat argument crossing a
// package boundary, several record types built off a cross-package pub val
// in one function) — with the "not ok" report naming only the whole test
// block, not which of the 5 helpers actually triggered it. Isolating each
// helper into its own test pinpoints the exact culprit on the next run
// instead of guessing at a fix blind.
test "messageListResp maps Ok to 200 and Err to the error's own status (#351)" {
  val noMessages: slice[Message] = []
  assertEqualInt(messageListResp(Ok(value = MessageList(messages = noMessages))).status, 200, "messageListResp Ok -> 200")
  assertEqualInt(messageListResp(Err(error = Web.badRequest("bad"))).status, 400, "messageListResp Err -> 400")
}

// Ok-path coverage for commentResp specifically is narrower than its four
// siblings: constructing a bare `Comment(...)` record here — CloudAgents.
// Repository's own package, imported unqualified exactly like Todo/Message/
// MessageList/CommentList/TodoList right above and below this test, all of
// which construct fine — crashes with a bare "Common Language Runtime
// detected an invalid program" (confirmed in CI; isolating this into its
// own test, split out from the combined block that originally caught it,
// pinned the crash to exactly this one construction). Not investigated
// further to a root cause — same "confirmed empirically, no known trigger
// condition" character as this codebase's other cataloged cross-package
// JIT crashes (docs/lyric/gotchas.md). Verified this doesn't affect
// production: `Comment(...)` is only ever constructed inside its own home
// package (repository.l's rowToComment/addComment) — commentResp itself
// only ever receives an already-built value and calls .toJson() on it, so
// the actual /comments route is unaffected. Reaching addComment here
// instead (to sidestep the crash) needs a live test DB for what's meant to
// be a lightweight Result->Response status-code check — the Err path below
// still exercises that mapping without needing any Comment at all.
test "commentResp maps Err to the error's own status (#351)" {
  assertEqualInt(commentResp(Err(error = Web.notFound("missing"))).status, 404, "commentResp Err -> 404")
}

test "commentListResp maps Ok to 200 and Err to the error's own status (#351)" {
  val noComments: slice[Comment] = []
  assertEqualInt(commentListResp(Ok(value = CommentList(comments = noComments))).status, 200, "commentListResp Ok -> 200")
  assertEqualInt(commentListResp(Err(error = Web.internalError("db down"))).status, 500, "commentListResp Err -> 500")
}

test "todoResp maps Ok to 200 and Err to the error's own status (#351)" {
  val todo = Todo(id = "t1", sessionId = "s1", messageId = "", note = "follow up", done = "0", createdAt = "1")
  assertEqualInt(todoResp(Ok(value = todo)).status, 200, "todoResp Ok -> 200")
  assertEqualInt(todoResp(Err(error = Web.badRequest("bad"))).status, 400, "todoResp Err -> 400")
}

test "todoListResp maps Ok to 200 and Err to the error's own status (#351)" {
  val noTodos: slice[Todo] = []
  assertEqualInt(todoListResp(Ok(value = TodoList(todos = noTodos))).status, 200, "todoListResp Ok -> 200")
  assertEqualInt(todoListResp(Err(error = Web.notFound("missing"))).status, 404, "todoListResp Err -> 404")
}

test "prompt Resp helpers map Ok to 200 and Err to the error's own status (#351)" {
  val noPrompts: slice[Prompt] = []
  assertEqualInt(promptListResp(Ok(value = PromptList(prompts = noPrompts))).status, 200, "promptListResp Ok -> 200")
  assertEqualInt(promptListResp(Err(error = Web.internalError("db down"))).status, 500, "promptListResp Err -> 500")

  assertEqualInt(renderedPromptResp(Ok(value = RenderedPrompt(rendered = "hi"))).status, 200, "renderedPromptResp Ok -> 200")
  assertEqualInt(renderedPromptResp(Err(error = Web.badRequest("bad"))).status, 400, "renderedPromptResp Err -> 400")

  val noTags: slice[String] = []
  val prompt = Prompt(id = "p1", userId = "u1", name = "n", body = "b", useCount = "0", createdAt = "1", updatedAt = "1", tags = noTags)
  assertEqualInt(promptResp(Ok(value = prompt)).status, 200, "promptResp Ok -> 200")
  assertEqualInt(promptResp(Err(error = Web.notFound("missing"))).status, 404, "promptResp Err -> 404")
}

test "credential/profile Resp helpers map Ok to 200 and Err to the error's own status (#351)" {
  val noCreds: slice[CredentialName] = []
  assertEqualInt(credentialNameListResp(Ok(value = CredentialNameList(credentials = noCreds))).status, 200, "credentialNameListResp Ok -> 200")
  assertEqualInt(credentialNameListResp(Err(error = Web.internalError("db down"))).status, 500, "credentialNameListResp Err -> 500")

  val noProfiles: slice[Profile] = []
  assertEqualInt(profileListResp(Ok(value = ProfileList(profiles = noProfiles))).status, 200, "profileListResp Ok -> 200")
  assertEqualInt(profileListResp(Err(error = Web.badRequest("bad"))).status, 400, "profileListResp Err -> 400")

  val noProfileCreds: slice[String] = []
  val profile = Profile(
    id = "p1",
    userId = "u1",
    name = "n",
    harness = "claude",
    networkPolicy = "full",
    credentialMode = "all",
    credentials = noProfileCreds,
    createdAt = "1",
    updatedAt = "1"
  )
  assertEqualInt(profileResp(Ok(value = profile)).status, 200, "profileResp Ok -> 200")
  assertEqualInt(profileResp(Err(error = Web.notFound("missing"))).status, 404, "profileResp Err -> 404")
}

test "webhook Resp helpers map Ok to 200 and Err to the error's own status (#351)" {
  val webhook = Webhook(id = "w1", userId = "u1", url = "https://example.com/hook", createdAt = "1")
  assertEqualInt(webhookResp(Ok(value = webhook)).status, 200, "webhookResp Ok -> 200")
  assertEqualInt(webhookResp(Err(error = Web.badRequest("bad"))).status, 400, "webhookResp Err -> 400")

  val noWebhooks: slice[Webhook] = []
  assertEqualInt(webhookListResp(Ok(value = WebhookList(webhooks = noWebhooks))).status, 200, "webhookListResp Ok -> 200")
  assertEqualInt(webhookListResp(Err(error = Web.internalError("db down"))).status, 500, "webhookListResp Err -> 500")

  val noEvents: slice[WebhookEvent] = []
  assertEqualInt(webhookEventListResp(Ok(value = WebhookEventList(events = noEvents))).status, 200, "webhookEventListResp Ok -> 200")
  assertEqualInt(webhookEventListResp(Err(error = Web.notFound("missing"))).status, 404, "webhookEventListResp Err -> 404")
}

test "MCP-callback Resp helpers map Ok to 200 and Err to the error's own status (#351)" {
  assertEqualInt(
    createPermissionRequestResp(Ok(value = CreatePermissionRequestResponse(id = "pr1", status = "pending"))).status,
    200,
    "createPermissionRequestResp Ok -> 200"
  )
  assertEqualInt(
    createPermissionRequestResp(Err(error = Web.badRequest("bad"))).status,
    400,
    "createPermissionRequestResp Err -> 400"
  )

  assertEqualInt(
    permissionDecisionResp(Ok(value = PermissionDecision(status = "allowed", updatedInputJson = "", note = ""))).status,
    200,
    "permissionDecisionResp Ok -> 200"
  )
  assertEqualInt(
    permissionDecisionResp(Err(error = Web.notFound("missing"))).status,
    404,
    "permissionDecisionResp Err -> 404"
  )

  assertEqualInt(
    createUserQuestionResp(Ok(value = CreateUserQuestionResponse(id = "q1"))).status,
    200,
    "createUserQuestionResp Ok -> 200"
  )
  assertEqualInt(
    createUserQuestionResp(Err(error = Web.internalError("db down"))).status,
    500,
    "createUserQuestionResp Err -> 500"
  )

  assertEqualInt(
    userQuestionAnswerResp(Ok(value = UserQuestionAnswer(status = "answered", answer = "42"))).status,
    200,
    "userQuestionAnswerResp Ok -> 200"
  )
  assertEqualInt(
    userQuestionAnswerResp(Err(error = Web.badRequest("bad"))).status,
    400,
    "userQuestionAnswerResp Err -> 400"
  )
}

test "HealthStatus.toJson() encodes the status field (#346/#360)" {
  assertEqual(HealthStatus(status = "Healthy").toJson(), "{\"status\":\"Healthy\"}", "matches the old hand-rolled shape")
}

// NOT covered here: HealthHandler.handle() / AuthMiddleware.wrap() end-to-end
// against a hand-constructed Web.Request. Filed as a tracked upstream defect
// (nichobbs/cloud-agents#354) rather than left only as this comment — see that
// issue for the full reproduction. Summary: constructing a Web.Request record
// (unqualified, per docs/lyric/gotchas.md's package-qualified-record-
// construction rule; with `import Std.Collections` for Map, ruled out as the
// cause by direct test) crashes at runtime with a bare "Common Language
// Runtime detected an invalid program" — reproduced twice, isolated to
// construction itself (HealthHandler.handle(req) fails even though it never
// reads a field of req). Web's public API has no alternative
// Request-constructing function to route around this. Does not prove the live
// server is broken: main.l's adapters only ever RECEIVE a Request as a
// parameter (from the framework) and read/query it — they never construct
// one, unlike this reverted test harness — so Handler/Middleware runtime
// behavior is exercised only implicitly via the real server
// (scripts/run-api.sh), not by an automated test, until this is resolved.

test "isValidPort accepts valid TCP ports" {
  assertTrue(isValidPort("1"), "minimum port")
  assertTrue(isValidPort("8080"), "common port")
  assertTrue(isValidPort("65535"), "maximum port")
}

test "isValidPort rejects invalid values" {
  assertFalse(isValidPort(""), "empty string")
  assertFalse(isValidPort("0"), "port zero")
  assertFalse(isValidPort("65536"), "just above maximum")
  assertFalse(isValidPort("123456"), "six digits")
  assertFalse(isValidPort("80a"), "trailing non-digit")
  assertFalse(isValidPort("-1"), "negative")
  assertFalse(isValidPort(" 80"), "leading space")
}
