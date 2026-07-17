package CloudAgents

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Credentials
import CloudAgents.Crypto
import CloudAgents.Docker
import CloudAgents.Handlers
import CloudAgents.Interactions
import CloudAgents.OAuth
import CloudAgents.Profiles
import CloudAgents.Prompts
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
pub record HealthHandler {}

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
pub record AuthMiddleware {}

impl Web.Middleware for AuthMiddleware {
  func wrap(req: in Web.Request, next: in Web.Handler): Web.Response {
    if req.path == "/api/health" or req.path.startsWith("/api/auth/") {
      // These handlers never read the per-request identity, but stamp the
      // operator id anyway so a pooled thread can't carry a previous
      // request's identity into any future code on these paths (#420).
      CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
      return next.handle(req)
    }
    var apiToken = Env.GetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN")
    if DotNetString.IsNullOrEmpty(apiToken) {
      apiToken = ""
    }
    val authHeader = match Web.header(req, "Authorization") {
      case Some(h) -> h
      case None -> ""
    }
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

func pparam(req: in Web.Request, name: in String): String {
  return match Web.pathParam(req, name) {
    case Some(s) -> s
    case None -> ""
  }
}

func badBody(): Web.Response {
  return Web.errorResponse(Web.badRequest("invalid JSON body"))
}

pub func unitResp(r: in Result[Unit, Web.ApiError]): Web.Response {
  return match r {
    case Ok(_) -> Web.noContent()
    case Err(e) -> Web.errorResponse(e)
  }
}

// listSessions / reapContainers / getRunOutput already build a complete JSON
// string themselves (see their bodies in sessions.l) — pass it through as-is.
pub func jsonStringResp(r: in Result[String, Web.ApiError]): Web.Response {
  return match r {
    case Ok(s) -> Web.json(200, s)
    case Err(e) -> Web.errorResponse(e)
  }
}

func createSessionResp(r: in Result[CreateSessionResponse, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func sessionProfileResp(r: in Result[SessionProfileRef, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func runListResp(r: in Result[RunList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func messageListResp(r: in Result[MessageList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func commentResp(r: in Result[Comment, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func commentListResp(r: in Result[CommentList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func todoResp(r: in Result[Todo, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func todoListResp(r: in Result[TodoList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func promptListResp(r: in Result[PromptList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func renderedPromptResp(r: in Result[RenderedPrompt, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func promptResp(r: in Result[Prompt, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func credentialNameListResp(r: in Result[CredentialNameList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func profileListResp(r: in Result[ProfileList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func profileResp(r: in Result[Profile, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func webhookResp(r: in Result[Webhook, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func webhookListResp(r: in Result[WebhookList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

func webhookEventListResp(r: in Result[WebhookEventList, Web.ApiError]): Web.Response {
  return match r {
    case Ok(v) -> Web.json(200, v.toJson())
    case Err(e) -> Web.errorResponse(e)
  }
}

// ─── CloudAgents.Handlers routes (sessions.l) ───────────────────────────────

record RouteCreateSession {}
impl Web.Handler for RouteCreateSession {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match CreateSessionRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return createSessionResp(CloudAgents.Handlers.createSession(decoded))
  }
}

record RouteSetSessionProfile {}
impl Web.Handler for RouteSetSessionProfile {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match SetProfileRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return unitResp(CloudAgents.Handlers.setSessionProfileHandler(id, decoded))
  }
}

record RouteGetSessionProfile {}
impl Web.Handler for RouteGetSessionProfile {
  func handle(req: in Web.Request): Web.Response {
    return sessionProfileResp(CloudAgents.Handlers.getSessionProfileHandler(pparam(req, "id")))
  }
}

record RouteListSessions {}
impl Web.Handler for RouteListSessions {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.listSessions())
  }
}

record RouteSendMessage {}
impl Web.Handler for RouteSendMessage {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match SendMessageRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    // The captured run output is pre-formatted as SSE frames (see
    // CloudAgents.Streaming), not JSON — text, not json, response.
    return match CloudAgents.Handlers.sendMessage(id, decoded) {
      case Ok(s) -> Web.text(200, s)
      case Err(e) -> Web.errorResponse(e)
    }
  }
}

record RouteCancelRun {}
impl Web.Handler for RouteCancelRun {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Handlers.cancelRun(pparam(req, "id")))
  }
}

record RouteGetRuns {}
impl Web.Handler for RouteGetRuns {
  func handle(req: in Web.Request): Web.Response {
    return runListResp(CloudAgents.Handlers.getRuns(pparam(req, "id")))
  }
}

record RouteReapContainers {}
impl Web.Handler for RouteReapContainers {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.reapContainers())
  }
}

record RouteGetRunOutput {}
impl Web.Handler for RouteGetRunOutput {
  func handle(req: in Web.Request): Web.Response {
    return jsonStringResp(CloudAgents.Handlers.getRunOutput(pparam(req, "id")))
  }
}

record RouteDeleteSession {}
impl Web.Handler for RouteDeleteSession {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Handlers.deleteSession(pparam(req, "id")))
  }
}

record RouteUpdateSessionModel {}
impl Web.Handler for RouteUpdateSessionModel {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match UpdateSessionRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return unitResp(CloudAgents.Handlers.updateSessionModel(id, decoded))
  }
}

// ─── CloudAgents.Interactions routes (interactions.l) ───────────────────────

record RouteGetMessages {}
impl Web.Handler for RouteGetMessages {
  func handle(req: in Web.Request): Web.Response {
    return messageListResp(CloudAgents.Interactions.getMessages(pparam(req, "id")))
  }
}

record RouteAddComment {}
impl Web.Handler for RouteAddComment {
  func handle(req: in Web.Request): Web.Response {
    val mid = pparam(req, "mid")
    val decoded = match AddCommentRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return commentResp(CloudAgents.Interactions.addCommentHandler(mid, decoded))
  }
}

record RouteGetComments {}
impl Web.Handler for RouteGetComments {
  func handle(req: in Web.Request): Web.Response {
    return commentListResp(CloudAgents.Interactions.getComments(pparam(req, "mid")))
  }
}

record RouteGetTodos {}
impl Web.Handler for RouteGetTodos {
  func handle(req: in Web.Request): Web.Response {
    return todoListResp(CloudAgents.Interactions.getTodos(pparam(req, "id")))
  }
}

record RouteAddTodo {}
impl Web.Handler for RouteAddTodo {
  func handle(req: in Web.Request): Web.Response {
    val id = pparam(req, "id")
    val decoded = match AddTodoRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return todoResp(CloudAgents.Interactions.addTodoHandler(id, decoded))
  }
}

record RouteToggleTodo {}
impl Web.Handler for RouteToggleTodo {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Interactions.toggleTodoHandler(pparam(req, "tid")))
  }
}

record RouteDeleteTodo {}
impl Web.Handler for RouteDeleteTodo {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Interactions.deleteTodoHandler(pparam(req, "tid")))
  }
}

// ─── CloudAgents.Prompts routes (prompts.l) ─────────────────────────────────

record RouteListPrompts {}
impl Web.Handler for RouteListPrompts {
  func handle(req: in Web.Request): Web.Response {
    return promptListResp(CloudAgents.Prompts.listPromptsHandler())
  }
}

record RouteListPopularPrompts {}
impl Web.Handler for RouteListPopularPrompts {
  func handle(req: in Web.Request): Web.Response {
    return promptListResp(CloudAgents.Prompts.listPopularPromptsHandler())
  }
}

record RouteListPromptsByTag {}
impl Web.Handler for RouteListPromptsByTag {
  func handle(req: in Web.Request): Web.Response {
    return promptListResp(CloudAgents.Prompts.listPromptsByTagHandler(pparam(req, "tag")))
  }
}

record RouteRenderPrompt {}
impl Web.Handler for RouteRenderPrompt {
  func handle(req: in Web.Request): Web.Response {
    val pid = pparam(req, "pid")
    val decoded = match RenderPromptRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return renderedPromptResp(CloudAgents.Prompts.renderPromptHandler(pid, decoded))
  }
}

record RouteAddPrompt {}
impl Web.Handler for RouteAddPrompt {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match SavePromptRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return promptResp(CloudAgents.Prompts.addPromptHandler(decoded))
  }
}

record RouteUpdatePrompt {}
impl Web.Handler for RouteUpdatePrompt {
  func handle(req: in Web.Request): Web.Response {
    val pid = pparam(req, "pid")
    val decoded = match SavePromptRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return promptResp(CloudAgents.Prompts.updatePromptHandler(pid, decoded))
  }
}

record RouteUsePrompt {}
impl Web.Handler for RouteUsePrompt {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Prompts.usePromptHandler(pparam(req, "pid")))
  }
}

record RouteDeletePrompt {}
impl Web.Handler for RouteDeletePrompt {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Prompts.deletePromptHandler(pparam(req, "pid")))
  }
}

// ─── CloudAgents.Credentials routes (credentials.l) ─────────────────────────

record RouteListCredentials {}
impl Web.Handler for RouteListCredentials {
  func handle(req: in Web.Request): Web.Response {
    return credentialNameListResp(CloudAgents.Credentials.listCredentialsHandler())
  }
}

record RoutePutCredential {}
impl Web.Handler for RoutePutCredential {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match PutCredentialRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return unitResp(CloudAgents.Credentials.putCredentialHandler(decoded))
  }
}

record RouteDeleteCredential {}
impl Web.Handler for RouteDeleteCredential {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Credentials.deleteCredentialHandler(pparam(req, "name")))
  }
}

// ─── CloudAgents.Profiles routes (profiles.l) ───────────────────────────────

record RouteListProfiles {}
impl Web.Handler for RouteListProfiles {
  func handle(req: in Web.Request): Web.Response {
    return profileListResp(CloudAgents.Profiles.listProfilesHandler())
  }
}

record RouteAddProfile {}
impl Web.Handler for RouteAddProfile {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match SaveProfileRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return profileResp(CloudAgents.Profiles.addProfileHandler(decoded))
  }
}

record RouteUpdateProfile {}
impl Web.Handler for RouteUpdateProfile {
  func handle(req: in Web.Request): Web.Response {
    val pid = pparam(req, "pid")
    val decoded = match SaveProfileRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return profileResp(CloudAgents.Profiles.updateProfileHandler(pid, decoded))
  }
}

record RouteDeleteProfile {}
impl Web.Handler for RouteDeleteProfile {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Profiles.deleteProfileHandler(pparam(req, "pid")))
  }
}

// ─── CloudAgents.Webhooks routes (webhooks.l) ───────────────────────────────

record RouteRegisterWebhook {}
impl Web.Handler for RouteRegisterWebhook {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match RegisterWebhookRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
    return webhookResp(CloudAgents.Webhooks.registerWebhookHandler(decoded))
  }
}

record RouteListWebhooks {}
impl Web.Handler for RouteListWebhooks {
  func handle(req: in Web.Request): Web.Response {
    return webhookListResp(CloudAgents.Webhooks.listWebhooksHandler())
  }
}

record RouteDeleteWebhook {}
impl Web.Handler for RouteDeleteWebhook {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Webhooks.deleteWebhookHandler(pparam(req, "id")))
  }
}

record RoutePendingWebhookEvents {}
impl Web.Handler for RoutePendingWebhookEvents {
  func handle(req: in Web.Request): Web.Response {
    return webhookEventListResp(CloudAgents.Webhooks.pendingWebhookEventsHandler())
  }
}

record RouteMarkWebhookDelivered {}
impl Web.Handler for RouteMarkWebhookDelivered {
  func handle(req: in Web.Request): Web.Response {
    return unitResp(CloudAgents.Webhooks.markWebhookDeliveredHandler(pparam(req, "id")))
  }
}

// ─── CloudAgents.OAuth routes (oauth.l) ─────────────────────────────────────

record RouteOAuthConfig {}
impl Web.Handler for RouteOAuthConfig {
  func handle(req: in Web.Request): Web.Response {
    return Web.json(200, CloudAgents.OAuth.configJson())
  }
}

record RouteOAuthExchange {}
impl Web.Handler for RouteOAuthExchange {
  func handle(req: in Web.Request): Web.Response {
    val decoded = match ExchangeRequest.fromJson(req.body) {
      case Ok(d) -> d
      case Err(_) -> return badBody()
    }
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
record RouteOAuthLogout {}
impl Web.Handler for RouteOAuthLogout {
  func handle(req: in Web.Request): Web.Response {
    val authHeader = match Web.header(req, "Authorization") {
      case Some(h) -> h
      case None -> ""
    }
    return unitResp(CloudAgents.OAuth.logout(authHeader))
  }
}

func main(): Unit {
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

  // Register session routes
  router = Web.addGet(router, "/api/sessions", RouteListSessions())
  router = Web.addPost(router, "/api/sessions", RouteCreateSession())
  router = Web.addPost(router, "/api/sessions/{id}/messages", RouteSendMessage())
  router = Web.addDelete(router, "/api/sessions/{id}", RouteDeleteSession())
  router = Web.addPost(router, "/api/sessions/{id}/model", RouteUpdateSessionModel())
  router = Web.addPost(router, "/api/sessions/{id}/profile", RouteSetSessionProfile())
  router = Web.addGet(router, "/api/sessions/{id}/profile", RouteGetSessionProfile())

  // Live output polling for an in-progress run
  router = Web.addGet(router, "/api/sessions/{id}/output", RouteGetRunOutput())

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
  Web.start(router)
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
  val stringType = getStringType("")
  val newArr = createStringArray(stringType, oldLen + 1)
  if oldLen > 0 {
    copyStringArray(arr, 0, newArr, 0, oldLen)
  }
  setStringArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyStringArray(): StringArray {
  val stringType = getStringType("")
  return createStringArray(stringType, 0)
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

@externInstance
@externTarget("System.Object.GetType")
func getStringType(obj: in String): Type = ()
