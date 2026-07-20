package CloudAgents

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Credentials
import CloudAgents.Crypto
import CloudAgents.Docker
import CloudAgents.Handlers
import CloudAgents.Interactions
import CloudAgents.OAuth
import CloudAgents.Profiles
import CloudAgents.Prompts
import CloudAgents.Proxy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Webhooks
import extern System.Environment as Env
import extern System.String as DotNetString

@generate(Json)
pub record HealthStatus {
  pub status: String
}

// Lyric.Web 0.4.26 dispatches to a Handler object per route ("addGet(router,
// pattern, handler: Handler)") rather than a handler-name string. This adapter
// bridges checkHealth() into that shape — see "Handler-adapter plumbing" below
// for the pattern all ~39 routes follow.
pub record HealthHandler {
}

impl Web.Handler for HealthHandler {
  func handle(req: in Web.Request): Web.Response {
    match CloudAgents.Handlers.checkHealth() {
      case Ok(msg) -> return Web.json(200, HealthStatus(status = msg).toJson())
      case Err(e) -> return Web.errorResponse(e)
    }
  }
}

// Auth-enforcement middleware — the seam the whole 0.4.26 adoption is for
// (#78/#211/#76). Reads the Authorization header (now exposed by Lyric.Web)
// and runs it through CloudAgents.OAuth.authenticateRequest: a bearer
// matching the static CLOUD_AGENTS_API_TOKEN authenticates as the operator
// (unchanged); any other bearer, when GitHub OAuth is configured, is
// validated as a GitHub token (cached, whitelisted) and resolves a real
// per-tenant identity; everything else keeps the pre-OAuth semantics
// (open when unconfigured, credential routes always refusing to run
// unauthenticated — #347). The resolved identity is stamped into the
// request thread before dispatch so Auth.currentUserId() scopes every
// query to the caller.
//
// /api/health is excluded so liveness checks don't need a token, and
// /api/auth/* is excluded because those endpoints exist to *obtain* a token.
pub record AuthMiddleware {
}

impl Web.Middleware for AuthMiddleware {
  func wrap(req: in Web.Request, next: in Web.Handler): Web.Response {
    if req.path == "/api/health" or req.path.startsWith("/api/auth/") or CloudAgents.Auth.isContainerCallbackRoute(req.path) {
      // These handlers never read the per-request identity, but stamp the
      // operator id anyway so a pooled thread can't carry a previous
      // request's identity into any future code on these paths (#420).
      // Container-originated MCP-callback routes (docs/phase6-mcp-callbacks.md
      // §5) authenticate themselves against the session's own callback
      // bearer token in CloudAgents.Callbacks — they carry no user
      // OAuth/static token to check here at all.
      CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
      return next.handle(req)
    }
    var apiToken = Env.GetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN")
    if DotNetString.IsNullOrEmpty(apiToken) {
      apiToken = ""
    }
    val authHeader = match Web.header(req, "Authorization") { case Some(h) -> h; case None -> "" }
    match CloudAgents.OAuth.authenticateRequest(req.path, authHeader, apiToken) {
      case Allowed(userId) -> {
        CloudAgents.Auth.setCurrentUserId(userId)
        return next.handle(req)
      }
      case Denied(e) -> return Web.errorResponse(Web.unauthorized(CloudAgents.Auth.authErrorMessage(e)))
    }
  }
}

// ─── Handler-adapter plumbing ───────────────────────────────────────────────
//
// Lyric.Web 0.4.26 dispatches to a `Handler` object (`func handle(req): Response`)
// per route rather than a string handler name. The handler functions in
// src/handlers/*.l are untouched — each adapter below just extracts path
// params / decodes the request-body record, calls the existing function, and maps its
// `Result[T, Web.ApiError]` to a `Response`. One response-mapping helper per
// distinct T (shared across routes that return the same type); one small
// stateless adapter record per route.
//
// badBody() and every *Resp helper below are `pub` (#351) so tests/main_tests.l
// can cover the Result -> Response mapping directly: they take/return only
// application records and Web.Response/Web.ApiError, none of which need a
// constructed Web.Request, unlike the RouteX.handle()/AuthMiddleware.wrap()
// adapters themselves (blocked by nichobbs/cloud-agents#354, see the NOTE in
// main_tests.l). pparam() is NOT exposed the same way — it takes a
// Web.Request, so it stays behind the same #354 wall as the route adapters.
func pparam(req: in Web.Request, name: in String): String {
  return match Web.pathParam(req, name) { case Some(s) -> s; case None -> "" }
}

pub func badBody(): Web.Response {
  return Web.errorResponse(Web.badRequest("invalid JSON body"))
}

pub func unitResp(r: in Result[Unit, Web.ApiError]): Web.Response {
  return match r { case Ok(_) -> Web.noContent(); case Err(e) -> Web.errorResponse(e) }
}

// listSessions / reapContainers / getRunOutput already build a complete JSON
// string themselves (see their bodies in sessions.l) — pass it through as-is.
pub func jsonStringResp(r: in Result[String, Web.ApiError]): Web.Response {
  return match r { case Ok(s) -> Web.json(200, s); case Err(e) -> Web.errorResponse(e) }
}

pub func createSessionResp(r: in Result[CreateSessionResponse, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func sessionProfileResp(r: in Result[SessionProfileRef, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func runListResp(r: in Result[RunList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func sessionRepoResp(r: in Result[SessionRepo, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func sessionRepoListResp(r: in Result[SessionRepoList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func messageListResp(r: in Result[MessageList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func commentResp(r: in Result[Comment, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func commentListResp(r: in Result[CommentList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func todoResp(r: in Result[Todo, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func todoListResp(r: in Result[TodoList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func promptListResp(r: in Result[PromptList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func renderedPromptResp(r: in Result[RenderedPrompt, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func promptResp(r: in Result[Prompt, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func credentialNameListResp(r: in Result[CredentialNameList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func profileListResp(r: in Result[ProfileList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func profileResp(r: in Result[Profile, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func webhookResp(r: in Result[Webhook, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func webhookListResp(r: in Result[WebhookList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func webhookEventListResp(r: in Result[WebhookEventList, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func createPermissionRequestResp(r: in Result[CreatePermissionRequestResponse, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func permissionDecisionResp(r: in Result[PermissionDecision, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func createUserQuestionResp(r: in Result[CreateUserQuestionResponse, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

pub func userQuestionAnswerResp(r: in Result[UserQuestionAnswer, Web.ApiError]): Web.Response {
  return match r { case Ok(v) -> Web.json(200, v.toJson()); case Err(e) -> Web.errorResponse(e) }
}

// ─── CloudAgents.Handlers routes (sessions.l) ───────────────────────────────
record RouteCreateSession {
}

impl Web.Handler for RouteCreateSession {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match CreateSessionRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return createSessionResp(CloudAgents.Handlers.createSession(decoded))
  }
}

record RouteSetSessionProfile {
}

impl Web.Handler for RouteSetSessionProfile {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match SetProfileRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return unitResp(CloudAgents.Handlers.setSessionProfileHandler(id, decoded))
  }
}

record RouteGetSessionProfile {
}

impl Web.Handler for RouteGetSessionProfile {
  func handle(req: in Web.Request): Web.Response {
    return sessionProfileResp(CloudAgents.Handlers.getSessionProfileHandler(pparam(req, "id")))
  }
}

record RouteListSessions {
}

impl Web.Handler for RouteListSessions {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.listSessions())
  }
}

// POST /api/sessions/{id}/messages is a STREAMING route (Lyric.Web 0.4.33): the
// handler writes SSE `data:` frames to the ResponseWriter as the container
// produces output, instead of buffering the whole run and returning one body.
// Registered in the separate StreamingRoutes table in main(), not the Router.
record SendMessageStreamHandler {
}

impl Web.StreamingHandler for SendMessageStreamHandler {
  func handleStream(req: in Web.Request, w: in Web.ResponseWriter): Unit {
    val id = pparam(req, "id")
    val decoded = match SendMessageRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> {
        // No chunk written yet, so a real 400 is still possible — reuse the
        // handler's shared pre-stream error writer (#490).
        CloudAgents.Handlers.writeStreamError(w, 400, "invalid JSON body")
        return ()
      }
    }
    CloudAgents.Handlers.streamSendMessage(id, decoded.text, w)
    return ()
  }
}

record RouteCancelRun {
}

impl Web.Handler for RouteCancelRun {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Handlers.cancelRun(pparam(req, "id")))
  }
}

record RouteGetRuns {
}

impl Web.Handler for RouteGetRuns {
  func handle(req: in Web.Request): Web.Response {
    return runListResp(CloudAgents.Handlers.getRuns(pparam(req, "id")))
  }
}

record RouteReapContainers {
}

impl Web.Handler for RouteReapContainers {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.reapContainers())
  }
}

record RouteGetRunOutput {
}

impl Web.Handler for RouteGetRunOutput {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.getRunOutput(pparam(req, "id")))
  }
}

record RouteGetRunOutputFrom {
}

impl Web.Handler for RouteGetRunOutputFrom {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.getRunOutputFrom(pparam(req, "id"), pparam(req, "offset")))
  }
}

record RouteDeleteSession {
}

impl Web.Handler for RouteDeleteSession {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Handlers.deleteSession(pparam(req, "id")))
  }
}

record RouteUpdateSessionModel {
}

impl Web.Handler for RouteUpdateSessionModel {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match UpdateSessionRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return unitResp(CloudAgents.Handlers.updateSessionModel(id, decoded))
  }
}

record RouteListSessionRepos {
}

impl Web.Handler for RouteListSessionRepos {
  func handle(req: in Web.Request): Web.Response {
    return sessionRepoListResp(CloudAgents.Handlers.listSessionReposHandler(pparam(req, "id")))
  }
}

record RouteAddSessionRepo {
}

impl Web.Handler for RouteAddSessionRepo {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match AddRepoRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return sessionRepoResp(CloudAgents.Handlers.addSessionRepoHandler(id, decoded))
  }
}

record RouteDeleteSessionRepo {
}

impl Web.Handler for RouteDeleteSessionRepo {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Handlers.deleteSessionRepoHandler(pparam(req, "id"), pparam(req, "rid")))
  }
}

// ─── CloudAgents.Interactions routes (interactions.l) ───────────────────────
record RouteGetMessages {
}

impl Web.Handler for RouteGetMessages {
  func handle(req: in Web.Request): Web.Response {
    return messageListResp(CloudAgents.Interactions.getMessages(pparam(req, "id")))
  }
}

record RouteAddComment {
}

impl Web.Handler for RouteAddComment {
  func handle(req: in Web.Request): Web.Response {
    val mid = pparam(req, "mid")
    val decoded = match AddCommentRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return commentResp(CloudAgents.Interactions.addCommentHandler(mid, decoded))
  }
}

record RouteGetComments {
}

impl Web.Handler for RouteGetComments {
  func handle(req: in Web.Request): Web.Response {
    return commentListResp(CloudAgents.Interactions.getComments(pparam(req, "mid")))
  }
}

record RouteGetTodos {
}

impl Web.Handler for RouteGetTodos {
  func handle(req: in Web.Request): Web.Response {
    return todoListResp(CloudAgents.Interactions.getTodos(pparam(req, "id")))
  }
}

record RouteAddTodo {
}

impl Web.Handler for RouteAddTodo {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match AddTodoRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return todoResp(CloudAgents.Interactions.addTodoHandler(id, decoded))
  }
}

record RouteToggleTodo {
}

impl Web.Handler for RouteToggleTodo {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Interactions.toggleTodoHandler(pparam(req, "tid")))
  }
}

record RouteDeleteTodo {
}

impl Web.Handler for RouteDeleteTodo {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Interactions.deleteTodoHandler(pparam(req, "tid")))
  }
}

// ─── CloudAgents.Prompts routes (prompts.l) ─────────────────────────────────
record RouteListPrompts {
}

impl Web.Handler for RouteListPrompts {
  func handle(req: in Web.Request): Web.Response {
    return promptListResp(CloudAgents.Prompts.listPromptsHandler())
  }
}

record RouteListPopularPrompts {
}

impl Web.Handler for RouteListPopularPrompts {
  func handle(req: in Web.Request): Web.Response {
    return promptListResp(CloudAgents.Prompts.listPopularPromptsHandler())
  }
}

record RouteListPromptsByTag {
}

impl Web.Handler for RouteListPromptsByTag {
  func handle(req: in Web.Request): Web.Response {
    return promptListResp(CloudAgents.Prompts.listPromptsByTagHandler(pparam(req, "tag")))
  }
}

record RouteRenderPrompt {
}

impl Web.Handler for RouteRenderPrompt {
  func handle(req: in Web.Request): Web.Response {
    val pid = pparam(req, "pid")
    val decoded = match RenderPromptRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return renderedPromptResp(CloudAgents.Prompts.renderPromptHandler(pid, decoded))
  }
}

record RouteAddPrompt {
}

impl Web.Handler for RouteAddPrompt {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match SavePromptRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return promptResp(CloudAgents.Prompts.addPromptHandler(decoded))
  }
}

record RouteUpdatePrompt {
}

impl Web.Handler for RouteUpdatePrompt {
  func handle(req: in Web.Request): Web.Response {
    val pid = pparam(req, "pid")
    val decoded = match SavePromptRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return promptResp(CloudAgents.Prompts.updatePromptHandler(pid, decoded))
  }
}

record RouteUsePrompt {
}

impl Web.Handler for RouteUsePrompt {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Prompts.usePromptHandler(pparam(req, "pid")))
  }
}

record RouteDeletePrompt {
}

impl Web.Handler for RouteDeletePrompt {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Prompts.deletePromptHandler(pparam(req, "pid")))
  }
}

// ─── CloudAgents.Credentials routes (credentials.l) ─────────────────────────
record RouteListCredentials {
}

impl Web.Handler for RouteListCredentials {
  func handle(req: in Web.Request): Web.Response {
    return credentialNameListResp(CloudAgents.Credentials.listCredentialsHandler())
  }
}

record RoutePutCredential {
}

impl Web.Handler for RoutePutCredential {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match PutCredentialRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return unitResp(CloudAgents.Credentials.putCredentialHandler(decoded))
  }
}

record RouteDeleteCredential {
}

impl Web.Handler for RouteDeleteCredential {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Credentials.deleteCredentialHandler(pparam(req, "name")))
  }
}

// ─── CloudAgents.Profiles routes (profiles.l) ───────────────────────────────
record RouteListProfiles {
}

impl Web.Handler for RouteListProfiles {
  func handle(req: in Web.Request): Web.Response {
    return profileListResp(CloudAgents.Profiles.listProfilesHandler())
  }
}

record RouteAddProfile {
}

impl Web.Handler for RouteAddProfile {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match SaveProfileRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return profileResp(CloudAgents.Profiles.addProfileHandler(decoded))
  }
}

record RouteUpdateProfile {
}

impl Web.Handler for RouteUpdateProfile {
  func handle(req: in Web.Request): Web.Response {
    val pid = pparam(req, "pid")
    val decoded = match SaveProfileRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return profileResp(CloudAgents.Profiles.updateProfileHandler(pid, decoded))
  }
}

record RouteDeleteProfile {
}

impl Web.Handler for RouteDeleteProfile {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Profiles.deleteProfileHandler(pparam(req, "pid")))
  }
}

// ─── CloudAgents.Webhooks routes (webhooks.l) ───────────────────────────────
record RouteRegisterWebhook {
}

impl Web.Handler for RouteRegisterWebhook {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match RegisterWebhookRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return webhookResp(CloudAgents.Webhooks.registerWebhookHandler(decoded))
  }
}

record RouteListWebhooks {
}

impl Web.Handler for RouteListWebhooks {
  func handle(req: in Web.Request): Web.Response {
    return webhookListResp(CloudAgents.Webhooks.listWebhooksHandler())
  }
}

record RouteDeleteWebhook {
}

impl Web.Handler for RouteDeleteWebhook {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Webhooks.deleteWebhookHandler(pparam(req, "id")))
  }
}

record RoutePendingWebhookEvents {
}

impl Web.Handler for RoutePendingWebhookEvents {
  func handle(req: in Web.Request): Web.Response {
    return webhookEventListResp(CloudAgents.Webhooks.pendingWebhookEventsHandler())
  }
}

record RouteMarkWebhookDelivered {
}

impl Web.Handler for RouteMarkWebhookDelivered {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Webhooks.markWebhookDeliveredHandler(pparam(req, "id")))
  }
}

// ─── CloudAgents.Callbacks routes (callbacks.l) ─────────────────────────────
//
// docs/phase6-mcp-callbacks.md. Create/poll routes are container-originated
// (callback-bearer-token authenticated, exempt from AuthMiddleware's normal
// check — see CloudAgents.Auth.isContainerCallbackRoute above); the
// `.../answer` routes are user-originated and flow through normal auth like
// every other route in this file.
func callbackAuthHeader(req: in Web.Request): String {
  return match Web.header(req, "Authorization") { case Some(h) -> h; case None -> "" }
}

record RouteCreatePermissionRequest {
}

impl Web.Handler for RouteCreatePermissionRequest {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match CreatePermissionRequestRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return createPermissionRequestResp(
      CloudAgents.Callbacks.createPermissionRequestHandler(id, callbackAuthHeader(req), decoded)
    )
  }
}

record RouteGetPermissionRequest {
}

impl Web.Handler for RouteGetPermissionRequest {
  func handle(req: in Web.Request): Web.Response {
    return permissionDecisionResp(
      CloudAgents.Callbacks.getPermissionRequestHandler(
        pparam(req, "id"),
        pparam(req, "rid"),
        callbackAuthHeader(req)
      )
    )
  }
}

record RouteAnswerPermissionRequest {
}

impl Web.Handler for RouteAnswerPermissionRequest {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val rid = pparam(req, "rid")
    val decoded = match AnswerPermissionRequestRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return unitResp(CloudAgents.Callbacks.answerPermissionRequestHandler(id, rid, decoded))
  }
}

record RouteCreateUserQuestion {
}

impl Web.Handler for RouteCreateUserQuestion {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match CreateUserQuestionRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return createUserQuestionResp(CloudAgents.Callbacks.createUserQuestionHandler(id, callbackAuthHeader(req), decoded))
  }
}

record RouteGetUserQuestion {
}

impl Web.Handler for RouteGetUserQuestion {
  func handle(req: in Web.Request): Web.Response {
    return userQuestionAnswerResp(
      CloudAgents.Callbacks.getUserQuestionHandler(pparam(req, "id"), pparam(req, "rid"), callbackAuthHeader(req))
    )
  }
}

record RouteAnswerUserQuestion {
}

impl Web.Handler for RouteAnswerUserQuestion {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val rid = pparam(req, "rid")
    val decoded = match AnswerUserQuestionRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return unitResp(CloudAgents.Callbacks.answerUserQuestionHandler(id, rid, decoded))
  }
}

record RouteReportProgress {
}

impl Web.Handler for RouteReportProgress {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match ReportProgressRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return unitResp(CloudAgents.Callbacks.reportProgressHandler(id, callbackAuthHeader(req), decoded))
  }
}

// ─── CloudAgents.Proxy routes (proxy.l) ─────────────────────────────────────
//
// Server-side provider proxies (ADR-006): every handler returns a complete
// passthrough JSON body as a String, so all five map through jsonStringResp.
record RouteProxyGithubRepos {
}

impl Web.Handler for RouteProxyGithubRepos {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Proxy.githubReposHandler(pparam(req, "page")))
  }
}

record RouteProxyGithubRepo {
}

impl Web.Handler for RouteProxyGithubRepo {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Proxy.githubRepoHandler(pparam(req, "owner"), pparam(req, "repo")))
  }
}

record RouteProxyGithubPulls {
}

impl Web.Handler for RouteProxyGithubPulls {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(
      CloudAgents.Proxy.githubPullsHandler(pparam(req, "owner"), pparam(req, "repo"), pparam(req, "branch"))
    )
  }
}

record RouteProxyGithubChecks {
}

impl Web.Handler for RouteProxyGithubChecks {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(
      CloudAgents.Proxy.githubChecksHandler(pparam(req, "owner"), pparam(req, "repo"), pparam(req, "branch"))
    )
  }
}

record RouteProxyModels {
}

impl Web.Handler for RouteProxyModels {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Proxy.modelsHandler(pparam(req, "harness")))
  }
}

// GET /api/harnesses (#523): which harnesses have a runner image on this
// deployment. Always succeeds — no Result to unwrap, unlike the other Proxy
// routes above.
record RouteHarnesses {
}

impl Web.Handler for RouteHarnesses {
  func handle(req: in Web.Request): Web.Response {
    return Web.json(200, CloudAgents.Proxy.harnessesHandler())
  }
}

// ─── CloudAgents.OAuth routes (oauth.l) ─────────────────────────────────────
record RouteOAuthConfig {
}

impl Web.Handler for RouteOAuthConfig {
  func handle(req: in Web.Request): Web.Response {
    return Web.json(200, CloudAgents.OAuth.configJson())
  }
}

record RouteOAuthExchange {
}

impl Web.Handler for RouteOAuthExchange {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match ExchangeRequest.fromJson(req.body) { case Ok(d) -> d; case Err(_) -> return badBody() }
    return match CloudAgents.OAuth.exchangeCode(decoded) {
      case Ok(grant) -> Web.json(200, grant.toJson())
      case Err(e) -> Web.errorResponse(e)
    }
  }
}

// Server-side logout: reads the Authorization header exactly as
// AuthMiddleware does and invalidates that bearer's validation-cache row.
// Lives under the auth-exempt /api/auth/ prefix, which is correct here:
// invalidating a cache row requires knowing the token itself.
record RouteOAuthLogout {
}

impl Web.Handler for RouteOAuthLogout {
  func handle(req: in Web.Request): Web.Response {
    val authHeader = match Web.header(req, "Authorization") { case Some(h) -> h; case None -> "" }
    return unitResp(CloudAgents.OAuth.logout(authHeader))
  }
}

// pub: dist/CloudAgents.Native/Program.cs (a separate assembly) calls into
// this entry point directly (global::CloudAgents.Program.main()). Without
// pub this is package-private per Lyric's documented visibility rules
// ("Package = visibility unit", docs/lyric/reference.md "Visibility") and
// only worked so far because .NET codegen doesn't yet enforce that across
// assembly boundaries — see nichobbs/cloud-agents#397.
pub func main(): Unit {
  // Ensure the SQLite tables (transcript/comments/todos/prompts/sessions)
  // exist before serving.
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to initialise database schema: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Sessions stranded RUNNING/WARM by a crash/restart can never be claimed
  // again (the concurrency guard would 409 forever). Terminate any container
  // they still reference before blanking it, so nothing is orphaned, then
  // reset the rows to IDLE.
  match CloudAgents.SessionStore.strandedContainerIds() {
    case Ok(ids) -> {
      for cid in ids {
        match CloudAgents.Docker.terminateSessionContainer(cid) {
          case Ok(_) -> ()
          case Err(e) -> println("WARNING: could not terminate stranded container " + cid + ": " + e)
        }
      }
    }
    case Err(e) -> println("WARNING: could not list stranded containers: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.SessionStore.recoverDanglingSessions() {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to recover dangling sessions: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Fail loudly at startup — not at first credential use — if ENCRYPTION_KEY
  // is set but unusable (wrong length, bad base64). A configured-but-broken
  // key would otherwise only surface when a user first stores a credential.
  if CloudAgents.Crypto.isConfigured() {
    match CloudAgents.Crypto.encrypt("startup-self-check") {
      case Ok(_) -> ()
      case Err(e) -> println("WARNING: ENCRYPTION_KEY is set but invalid — credential storage will fail: " + CloudAgents.Crypto.cryptoErrorMessage(e))
    }
  } else {
    println("NOTE: ENCRYPTION_KEY is not set — the credential store is disabled")
  }

  // One-time migration of sessions from the legacy env-var store.
  CloudAgents.SessionStore.importLegacyEnvSessions()

  var router = Web.create()

  // Register session routes. NOTE: POST /api/sessions/{id}/messages is NOT here
  // — it's a streaming route registered in the StreamingRoutes table below.
  router = Web.addGet(router, "/api/sessions", RouteListSessions())
  router = Web.addPost(router, "/api/sessions", RouteCreateSession())
  router = Web.addDelete(router, "/api/sessions/{id}", RouteDeleteSession())
  router = Web.addPost(router, "/api/sessions/{id}/model", RouteUpdateSessionModel())
  router = Web.addPost(router, "/api/sessions/{id}/profile", RouteSetSessionProfile())
  router = Web.addGet(router, "/api/sessions/{id}/profile", RouteGetSessionProfile())

  // Live output polling for an in-progress run. The offset-suffixed route
  // returns only the log bytes past {offset} (incremental polling — see
  // getRunOutputFrom); the plain route returns the full log each tick and is
  // kept untouched for older clients.
  //
  // NOTE (#442): the offset route is this codebase's first multi-path-param
  // pattern (the proxy routes below add more). @test_module suites can't
  // exercise it (Web.Request can't be constructed in a test, #354), so
  // scripts/e2e-http.sh now starts the built server in CI and curls this exact
  // route (expecting a 404 for an unknown session) to prove multi-param
  // dispatch works. Clients also degrade gracefully if it ever regresses:
  // useStreamMessage falls back to the plain full-log route on any delta
  // error, and the proxy clients fall back to direct GitHub/provider calls.
  router = Web.addGet(router, "/api/sessions/{id}/output", RouteGetRunOutput())
  router = Web.addGet(router, "/api/sessions/{id}/output/{offset}", RouteGetRunOutputFrom())

  // Linked repositories (multi-repo sessions): list, add, and remove extra
  // repositories an agent works across in one run. The DELETE route is a
  // two-path-param pattern ({id} and {rid}); multi-param dispatch is now
  // covered in CI by scripts/e2e-http.sh via the /output/{offset} route
  // (#442). The frontend also degrades gracefully (hides the panel) if the
  // routes 404 on an older backend.
  router = Web.addGet(router, "/api/sessions/{id}/repos", RouteListSessionRepos())
  router = Web.addPost(router, "/api/sessions/{id}/repos", RouteAddSessionRepo())
  router = Web.addDelete(router, "/api/sessions/{id}/repos/{rid}", RouteDeleteSessionRepo())

  // Session lifecycle: cancel an in-flight run, run history, container reaping.
  router = Web.addPost(router, "/api/sessions/{id}/cancel", RouteCancelRun())
  router = Web.addGet(router, "/api/sessions/{id}/runs", RouteGetRuns())
  router = Web.addPost(router, "/api/maintenance/reap", RouteReapContainers())

  // Transcript: addressable agent/user messages for a session
  router = Web.addGet(router, "/api/sessions/{id}/messages", RouteGetMessages())

  // Comments anchored to a specific message
  router = Web.addPost(router, "/api/messages/{mid}/comments", RouteAddComment())
  router = Web.addGet(router, "/api/messages/{mid}/comments", RouteGetComments())

  // Todos / bookmarks, optionally linked back to a message
  router = Web.addGet(router, "/api/sessions/{id}/todos", RouteGetTodos())
  router = Web.addPost(router, "/api/sessions/{id}/todos", RouteAddTodo())
  router = Web.addPost(router, "/api/todos/{tid}/toggle", RouteToggleTodo())
  router = Web.addDelete(router, "/api/todos/{tid}", RouteDeleteTodo())

  // Prompt library: saved, reusable prompts
  router = Web.addGet(router, "/api/prompts", RouteListPrompts())
  router = Web.addGet(router, "/api/prompts/popular", RouteListPopularPrompts())
  router = Web.addGet(router, "/api/prompts/tag/{tag}", RouteListPromptsByTag())
  router = Web.addPost(router, "/api/prompts", RouteAddPrompt())
  router = Web.addPost(router, "/api/prompts/{pid}", RouteUpdatePrompt())
  router = Web.addPost(router, "/api/prompts/{pid}/use", RouteUsePrompt())
  router = Web.addPost(router, "/api/prompts/{pid}/render", RouteRenderPrompt())
  router = Web.addDelete(router, "/api/prompts/{pid}", RouteDeletePrompt())

  // Credential store: per-user secrets injected into runner containers.
  // Write-only — values are never read back, only their names.
  router = Web.addGet(router, "/api/credentials", RouteListCredentials())
  router = Web.addPost(router, "/api/credentials", RoutePutCredential())
  router = Web.addDelete(router, "/api/credentials/{name}", RouteDeleteCredential())

  // Profiles: per-container policy (harness, network access, injected creds).
  router = Web.addGet(router, "/api/profiles", RouteListProfiles())
  router = Web.addPost(router, "/api/profiles", RouteAddProfile())
  router = Web.addPost(router, "/api/profiles/{pid}", RouteUpdateProfile())
  router = Web.addDelete(router, "/api/profiles/{pid}", RouteDeleteProfile())

  // Webhooks: run-completion notifications (outbox delivered by an external
  // worker that polls /pending and marks events delivered).
  router = Web.addGet(router, "/api/webhooks", RouteListWebhooks())
  router = Web.addPost(router, "/api/webhooks", RouteRegisterWebhook())
  router = Web.addGet(router, "/api/webhooks/pending", RoutePendingWebhookEvents())
  router = Web.addPost(router, "/api/webhooks/events/{id}/delivered", RouteMarkWebhookDelivered())
  router = Web.addDelete(router, "/api/webhooks/{id}", RouteDeleteWebhook())

  // MCP callbacks (docs/phase6-mcp-callbacks.md): permission requests, user
  // questions, and progress reports from the in-container MCP shim (stage 3,
  // not shipped yet — CLOUD_AGENTS_MCP_CALLBACKS is off by default so no
  // container ever calls these today). Create/poll routes are
  // container-originated (callback-bearer-token auth, exempt from
  // AuthMiddleware — see isContainerCallbackRoute); the .../answer routes are
  // user-originated and auth-enforced like every other route below.
  router = Web.addPost(router, "/api/sessions/{id}/callbacks/permission", RouteCreatePermissionRequest())
  router = Web.addGet(router, "/api/sessions/{id}/callbacks/permission/{rid}", RouteGetPermissionRequest())
  router = Web.addPost(router, "/api/sessions/{id}/callbacks/permission/{rid}/answer", RouteAnswerPermissionRequest())
  router = Web.addPost(router, "/api/sessions/{id}/callbacks/question", RouteCreateUserQuestion())
  router = Web.addGet(router, "/api/sessions/{id}/callbacks/question/{rid}", RouteGetUserQuestion())
  router = Web.addPost(router, "/api/sessions/{id}/callbacks/question/{rid}/answer", RouteAnswerUserQuestion())
  router = Web.addPost(router, "/api/sessions/{id}/callbacks/progress", RouteReportProgress())

  // Server-side provider proxies (ADR-006): GitHub listings and model
  // discovery with vault credentials, so the browser needs no local keys.
  // NOTE: a branch name containing '/' cannot match the single {branch}
  // segment below — an accepted limitation; the frontend falls back to
  // direct GitHub calls when the proxy 404s/errors on such branches.
  router = Web.addGet(router, "/api/github/repos/{page}", RouteProxyGithubRepos())
  router = Web.addGet(router, "/api/github/repos/{owner}/{repo}", RouteProxyGithubRepo())
  router = Web.addGet(router, "/api/github/pulls/{owner}/{repo}/{branch}", RouteProxyGithubPulls())
  router = Web.addGet(router, "/api/github/checks/{owner}/{repo}/{branch}", RouteProxyGithubChecks())
  router = Web.addGet(router, "/api/models/{harness}", RouteProxyModels())
  router = Web.addGet(router, "/api/harnesses", RouteHarnesses())

  // GitHub OAuth: public login configuration, the code-for-token exchange,
  // and logout (all exempt from auth enforcement — config/exchange exist to
  // obtain a token, and logout only ever invalidates the cache row of the
  // exact token presented).
  router = Web.addGet(router, "/api/auth/github/config", RouteOAuthConfig())
  router = Web.addPost(router, "/api/auth/github/exchange", RouteOAuthExchange())
  router = Web.addPost(router, "/api/auth/github/logout", RouteOAuthLogout())

  // Register health route
  router = Web.addGet(router, "/api/health", HealthHandler())

  router = Web.withMiddleware(router, AuthMiddleware())

  // Streaming routes (Lyric.Web 0.4.33), served alongside the Router by
  // startStreaming below. A request that doesn't match a streaming route falls
  // through to the Router unchanged; router.middlewares (AuthMiddleware) run
  // first for BOTH tables, so the streaming send endpoint is auth-enforced and
  // identity-stamped exactly like every other route.
  var streaming = Web.emptyStreamingRoutes()
  streaming = Web.addStreamingPost(streaming, "/api/sessions/{id}/messages", SendMessageStreamHandler())

  // Parse command line arguments for --port or -p
  val cmdLine = Env.get_CommandLine()
  val args = parseCommandLine(cmdLine)
  val argsLen = getStringArrayLength(args)
  var portStr = ""

  var idx = 1
  while idx < argsLen {
    val arg = getStringArrayValue(args, idx)
    if arg == "--port" or arg == "-p" {
      if idx + 1 < argsLen {
        portStr = getStringArrayValue(args, idx + 1)
      }
    }
    idx = idx + 1
  }

  // CLI takes precedence; otherwise read from env var
  if DotNetString.IsNullOrEmpty(portStr) {
    portStr = Env.GetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT")
  }

  // Fallback to default port if not set
  if DotNetString.IsNullOrEmpty(portStr) {
    portStr = "8080"
  }

  // The Web.Server config range-checks this env var at startup and panics on
  // violation; validating here turns a typo into a warning instead of a crash.
  if not isValidPort(portStr) {
    println("WARNING: '" + portStr + "' is not a valid TCP port (1-65535); using 8080")
    portStr = "8080"
  }
  Env.SetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT", portStr)

  println("Starting Cloud Agents API Server on port " + portStr + "...")
  Web.startStreaming(router, streaming)
}

func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

/// Whether `s` is a decimal TCP port in 1..65535.
pub func isValidPort(s: in String): Bool {
  if s.length == 0 or s.length > 5 {
    return false
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return false
    }
    n = n * 10 + d
    i = i + 1
  }
  return n >= 1 and n <= 65535
}

pub func parseCommandLine(cmdLine: in String): StringArray {
  var entries = createEmptyStringArray()
  var current = ""
  var i = 0
  while i < cmdLine.length {
    val c = cmdLine.substring(i, 1)
    if c == " " {
      val trimmed = current.trim()
      if trimmed.length > 0 {
        entries = appendString(entries, trimmed)
      }
      current = ""
    } else {
      current = current + c
    }
    i = i + 1
  }
  val lastTrimmed = current.trim()
  if lastTrimmed.length > 0 {
    entries = appendString(entries, lastTrimmed)
  }
  return entries
}

pub func appendString(arr: in StringArray, item: in String): StringArray {
  val oldLen = getStringArrayLength(arr)
  val strType = stringType("System.String")
  val newArr = createStringArray(strType, oldLen + 1)
  if oldLen > 0 {
    copyStringArray(arr, 0, newArr, 0, oldLen)
  }
  setStringArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyStringArray(): StringArray {
  val strType = stringType("System.String")
  return createStringArray(strType, 0)
}

extern type Type = "System.Type"

extern type StringArray = "System.String[]"

@externInstance
@externTarget("System.Array.get_Length")
func getStringArrayLength(arr: in StringArray): Int = ()

@externInstance
@externTarget("System.Array.GetValue")
func getStringArrayValue(arr: in StringArray, index: in Int): String = ()

@externInstance
@externTarget("System.Array.SetValue")
func setStringArrayValue(arr: in StringArray, value: in String, index: in Int): Unit = ()

@externTarget("System.Array.CreateInstance")
func createStringArray(elementType: in Type, length: in Int): StringArray = ()

@externTarget("System.Array.Copy")
func copyStringArray(
  sourceArray: in StringArray,
  sourceIndex: in Int,
  destinationArray: in StringArray,
  destinationIndex: in Int,
  length: in Int,
): Unit = ()

// Static Type.GetType(string), not an @externInstance-bound Object.GetType()
// on a boxed argument (#513) — the same instance-bound GetType() shape that
// crashed the process with an uncatchable AccessViolationException for a
// boxed Byte (docs/lyric/gotchas.md), migrated here as defense-in-depth even
// though String is a reference type and the specific boxing-mismatch
// mechanism described there is scoped to value-type arguments. Same pattern
// as src/github_api.l's typeFromName.
@externTarget("System.Type.GetType")
func stringType(name: in String): Type = ()
