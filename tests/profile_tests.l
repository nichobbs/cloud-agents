//! Profile tests: validation, and the profile store (grants, tools, network
//! policy, credential injection) on Postgres since the phase 11 cut-over.
@test_module
package CloudAgents.ProfileTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Profiles
import CloudAgents.Repository
import CloudAgents.Scope
import CloudAgents.Db
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

// Own tiny UTF-8-decode FFI surface, mirroring CloudAgents.LibrarySeed's/
// CloudAgents.McpServerSeed's bytesToUtf8 (see their doc comments) rather
// than importing another package's — needed below to read the raw bytes a
// Web.Response actually carries, since @generate(Json)'s .toJson() only
// gives us a String to compare against, not a way to inspect the Response.
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func bytesToUtf8(enc: in Encoding, bytes: in slice[Byte]): String = ""

test "handler validation rejects bad enums" {
  assertTrue(isValidNetworkPolicy("full"), "full is valid")
  assertTrue(isValidNetworkPolicy("none"), "none is valid")
  assertTrue(isValidNetworkPolicy("restricted"), "restricted is valid")
  assertTrue(not isValidNetworkPolicy("open"), "unknown policy rejected")
  assertTrue(isValidCredentialMode("all") and isValidCredentialMode("selected"), "credential modes")
  assertTrue(not isValidCredentialMode("some"), "unknown mode rejected")
  assertTrue(isValidProfileHarness("") and isValidProfileHarness("claude"), "empty and claude harness ok")
  assertTrue(isValidProfileHarness("gemini"), "gemini harness ok")
  assertTrue(isValidProfileHarness("antigravity"), "antigravity harness ok")
  assertTrue(not isValidProfileHarness("bogus"), "unknown harness rejected")
  assertTrue(isValidToolMode("all") and isValidToolMode("selected"), "tool modes")
  assertTrue(not isValidToolMode("some"), "unknown tool mode rejected")
  assertTrue(isValidToolName("remember") and isValidToolName("request_permission"), "known tool names accepted")
  assertTrue(not isValidToolName("delete_everything"), "unknown tool name rejected")
  // notify (phase 7 §5) is a real, always-registerable shim tool — an
  // earlier revision of this list omitted it (#625), which meant a
  // 'selected'-mode profile could never explicitly grant it even though
  // the shim always ran it ungated regardless of any profile's tool_mode.
  assertTrue(isValidToolName("notify"), "notify is a valid tool name (#625)")
}

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: profile tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
}

func mustProfile(r: in Result[Profile, CloudAgents.Db.DbError]): Profile {
  return match r { case Ok(p) -> p; case Err(e) -> panic("profile op failed: " + CloudAgents.Db.dbErrorMessage(e)) }
}

func mustProfiles(r: in Result[slice[Profile], CloudAgents.Db.DbError]): slice[Profile] {
  return match r {
    case Ok(ps) -> ps
    case Err(e) -> panic("profile list failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mustRows(r: in Result[Int, CloudAgents.Db.DbError]): Int {
  return match r {
    case Ok(n) -> n
    case Err(e) -> panic("profile write failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mustPutCredential(userId: in String, name: in String, value: in String): Unit {
  match putCredential(CloudAgents.Scope.userScope(userId), name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + credentialErrorMessage(e))
  }
}

func mustProfileCreds(r: in Result[slice[CredentialValue], CredentialError]): slice[CredentialValue] {
  return match r { case Ok(cs) -> cs; case Err(e) -> panic("profile creds failed: " + credentialErrorMessage(e)) }
}

func hasCred(creds: in slice[CredentialValue], name: in String): Bool {
  var i = 0
  while i < creds.length {
    if creds[i].name == name {
      return true
    }
    i = i + 1
  }
  return false
}

test "Profile handlers validate enums, grants, and reject duplicates" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-handlers")
  // Bad network policy -> 400.
  match addProfileHandler(SaveProfileRequest(name = "p", harness = "", networkPolicy = "open", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "all", tools = [])) {
    case Ok(_) -> assertTrue(false, "bad policy should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad policy -> 400")
  }
  // Invalid grant name (#237) -> 400.
  match addProfileHandler(SaveProfileRequest(name = "p2", harness = "", networkPolicy = "none", credentialMode = "selected", credentials = ["bad name"], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "all", tools = [])) {
    case Ok(_) -> assertTrue(false, "bad grant name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad grant -> 400")
  }
  // Bad tool mode -> 400.
  match addProfileHandler(SaveProfileRequest(name = "p3", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "some", tools = [])) {
    case Ok(_) -> assertTrue(false, "bad tool mode should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad tool mode -> 400")
  }
  // Unknown tool name (docs/phase7-autonomy.md §7) -> 400.
  match addProfileHandler(SaveProfileRequest(name = "p4", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "selected", tools = ["not_a_real_tool"])) {
    case Ok(_) -> assertTrue(false, "unknown tool name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "unknown tool name -> 400")
  }
  // toolMode 'selected' with zero tools chosen -> 400, not a silent collapse
  // to 'all' (#616): the opposite of credentialMode's fail-closed behavior
  // for the analogous zero-grants case would otherwise surprise an operator
  // deselecting every tool expecting a locked-down profile.
  match addProfileHandler(SaveProfileRequest(name = "p5", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "selected", tools = [])) {
    case Ok(_) -> assertTrue(false, "'selected' toolMode with zero tools should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "selected + zero tools -> 400")
  }
  // Happy path.
  match addProfileHandler(SaveProfileRequest(name = "prod", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "all", tools = [])) {
    case Ok(p) -> assertEqual(p.name, "prod", "profile created")
    case Err(_) -> assertTrue(false, "valid profile should create")
  }
  // Duplicate name (#236) -> 400, not a 500 from the UNIQUE constraint.
  match addProfileHandler(SaveProfileRequest(name = "prod", harness = "", networkPolicy = "full", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "all", tools = [])) {
    case Ok(_) -> assertTrue(false, "duplicate name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "duplicate name -> 400")
  }
  // Unknown ids are 404s.
  match updateProfileHandler("nope", SaveProfileRequest(name = "x", harness = "", networkPolicy = "full", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "all", tools = [])) {
    case Ok(_) -> assertTrue(false, "unknown update should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown update -> 404")
  }
  match deleteProfileHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown delete should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown delete -> 404")
  }
}

test "an absent/empty toolMode (a not-yet-updated frontend) defaults to 'all', not a 400 (#614)" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-toolmode-default")
  // Exactly the shape a pre-phase-7 frontend still sends: toolMode/tools
  // never populated. Must succeed, not 400 — every existing profile
  // create/update from the current UI would otherwise break the moment
  // this ships.
  val created = match addProfileHandler(SaveProfileRequest(name = "legacy-client", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "", tools = [])) {
    case Ok(p) -> p
    case Err(err) -> panic("an absent toolMode must not be rejected: " + toString(err.status))
  }
  assertEqual(created.toolMode, "all", "empty toolMode is normalized and stored as 'all'")

  val updated = match updateProfileHandler(created.id, SaveProfileRequest(name = "legacy-client", harness = "", networkPolicy = "full", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "", tools = [])) {
    case Ok(p) -> p
    case Err(err) -> panic("an absent toolMode on update must not be rejected: " + toString(err.status))
  }
  assertEqual(updated.toolMode, "all", "empty toolMode still normalizes to 'all' on update")
}

test "SaveProfileRequest.fromJson decodes a body that omits toolMode/tools entirely, exactly what the live unmodified frontend sends (#614)" {
  // The scenario the #614 fix's other test never actually covered: it
  // constructs SaveProfileRequest directly in Lyric, never via .fromJson —
  // so it never exercised whether the real decode boundary in src/main.l
  // (SaveProfileRequest.fromJson(patchMissingToolFields(req.body))) even
  // succeeds when the JSON body omits both keys, as the deployed frontend
  // does (this PR is backend-only). @generate(Json)'s derived fromJson has
  // no per-field default: confirmed separately that it fails outright with
  // "missing field '<name>'" on an absent field, for String, slice[T], AND
  // Option[T] alike — so without patchMissingToolFields this request would
  // 400 at decode time regardless of validateSaveProfile's own tolerance.
  val rawBody = "{\"name\":\"legacy-client\",\"harness\":\"\",\"networkPolicy\":\"none\",\"credentialMode\":\"all\",\"credentials\":[],\"skillIds\":[],\"subagentIds\":[],\"mcpServerIds\":[]}"
  val patched = patchMissingToolFields(rawBody)
  val decoded = match SaveProfileRequest.fromJson(patched) {
    case Ok(d) -> d
    case Err(e) -> panic("a body omitting toolMode/tools must still decode: " + toString(e))
  }
  assertEqual(decoded.name, "legacy-client", "every field the body DID send round-trips")
  assertEqual(decoded.toolMode, "", "the omitted toolMode decodes to its JSON zero-value")
  assertEqualInt(decoded.tools.length.toInt(), 0, "the omitted tools decodes to an empty list")

  // A body that already sends both fields must decode byte-identically to
  // patching nothing (no double-injected keys, no corrupted trailing JSON).
  val alreadyPresent = "{\"name\":\"x\",\"harness\":\"\",\"networkPolicy\":\"none\",\"credentialMode\":\"all\",\"credentials\":[],\"skillIds\":[],\"subagentIds\":[],\"mcpServerIds\":[],\"toolMode\":\"selected\",\"tools\":[\"remember\"]}"
  assertEqual(
    patchMissingToolFields(alreadyPresent),
    alreadyPresent,
    "a body that already has both fields is passed through unchanged"
  )
  val decodedAlreadyPresent = match SaveProfileRequest.fromJson(patchMissingToolFields(alreadyPresent)) {
    case Ok(d) -> d
    case Err(e) -> panic("an already-complete body must still decode: " + toString(e))
  }
  assertEqual(decodedAlreadyPresent.toolMode, "selected", "an explicitly-sent toolMode is preserved, not overwritten")
  assertEqualInt(decodedAlreadyPresent.tools.length.toInt(), 1, "an explicitly-sent tools list is preserved")
}

test "duplicate tool names in 'selected' mode are rejected (#615)" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-toolmode-dup")
  match addProfileHandler(SaveProfileRequest(name = "dup-tools", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "selected", tools = ["remember", "recall", "remember"])) {
    case Ok(_) -> assertTrue(false, "a repeated tool name must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "duplicate tool name -> 400")
  }
}

test "Profile CRUD round-trips with its credential grants" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-crud")
  val userId = me

  val created = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "locked-down",
      "claude",
      "none",
      "selected",
      ["GITHUB_TOKEN"],
      [],
      [],
      [],
      "selected",
      ["remember", "recall"]
    )
  )
  assertTrue(created.id.length > 0, "created profile has an id")
  assertEqual(created.networkPolicy, "none", "network policy stored")
  assertEqualInt(created.credentials.length.toInt(), 1, "one credential granted")
  assertEqual(created.toolMode, "selected", "tool mode stored")
  assertEqualInt(created.tools.length.toInt(), 2, "two tools granted")

  val listed = mustProfiles(listProfiles(CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(listed.length.toInt(), 1, "one profile listed")
  assertEqual(listed[0].name, "locked-down", "listed profile name matches")
  assertEqualInt(listed[0].credentials.length.toInt(), 1, "grants come back with the profile")
  assertEqualInt(listed[0].tools.length.toInt(), 2, "tool grants come back with the profile")

  // Update: switch to full network + all credentials + all tools (grants
  // and tool grants should both clear).
  val updated = mustRows(
    updateProfile(
      created.id,
      CloudAgents.Pg.personalScope(userId),
      "opened-up",
      "",
      "full",
      "all",
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )
  assertEqualInt(updated, 1, "update touches one row")
  match getProfile(created.id, CloudAgents.Pg.personalScope(userId)) {
    case Ok(Some(p)) -> {
      assertEqual(p.networkPolicy, "full", "network policy updated")
      assertEqual(p.credentialMode, "all", "credential mode updated")
      assertEqualInt(p.credentials.length.toInt(), 0, "grants cleared on switch to all")
      assertEqual(p.toolMode, "all", "tool mode updated")
      assertEqualInt(p.tools.length.toInt(), 0, "tool grants cleared on switch to all")
    }
    case Ok(None) -> assertTrue(false, "updated profile should exist")
    case Err(e) -> assertTrue(false, "getProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  val deleted = mustRows(deleteProfile(created.id, CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(deleted, 1, "delete touches one row")
  assertEqualInt(
    mustProfiles(listProfiles(CloudAgents.Pg.personalScope(userId))).length.toInt(),
    0,
    "empty after delete"
  )
}

// Regression coverage for #734: PR #729 fixed profileResp/profileListResp
// (and ~35 other *Resp helpers in src/main.l) double-serializing their JSON
// bodies by switching from `Web.json(200, v.toJson())` (which JSON-encodes
// its second argument AGAIN, wrapping an already-serialized object in an
// extra pair of quotes with every inner `"` backslash-escaped) to
// `jsonResp(200, v.toJson())` (`Web.text` + an explicit `Content-Type:
// application/json` header, which sends the string byte-for-byte). Neither
// tests/main_tests.l's own Resp-helper suite (asserts only `.status` — see
// its doc comment on Web.Response exposing no documented body accessor) nor
// scripts/e2e-http.sh's substring `assert` (a double-encoded
// `"{\"status\":\"ok\"}"` still contains the substring `status`) would catch
// a reintroduction of the bug. This test reads the Response's own
// `bodyBytes`/`contentType` fields directly to close that gap for the
// profiles handlers.
// The Content-Type header is deliberately not asserted here: jsonResp sets it
// via Web.withResponseHeader, so it lives in Response.headers (whose runtime
// Map does not answer .get(), and Lyric.Web exposes no reader for it), while
// the record's contentType field keeps Web.text's text/plain default.
test "Profile Resp helpers emit the raw profile JSON, not a double-encoded JSON string (#734)" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-jsonresp")
  val p = match addProfileHandler(SaveProfileRequest(name = "json-check", harness = "", networkPolicy = "none", credentialMode = "all", credentials = [], skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "all", tools = [])) {
    case Ok(v) -> v
    case Err(_) -> panic("setup: profile create failed")
  }

  val single = profileResp(Ok(value = p))
  assertEqualInt(single.status, 200, "profileResp Ok -> 200")
  val singleBody = bytesToUtf8(utf8Encoding(), single.bodyBytes)
  assertEqual(
    singleBody,
    p.toJson(),
    "profileResp's body is byte-identical to Profile.toJson() — a double-serialized body would instead be that string JSON-encoded again (wrapped in quotes, inner quotes backslash-escaped)"
  )
  assertTrue(not singleBody.startsWith("\""), "a JSON object body must start with '{', not an escaping quote")

  val list = profileListResp(Ok(value = ProfileList(profiles = [p])))
  assertEqualInt(list.status, 200, "profileListResp Ok -> 200")
  val listBody = bytesToUtf8(utf8Encoding(), list.bodyBytes)
  assertEqual(
    listBody,
    ProfileList(profiles = [p]).toJson(),
    "profileListResp's body is byte-identical to ProfileList.toJson(), not double-encoded"
  )
  assertTrue(not listBody.startsWith("\""), "a JSON object body must start with '{', not an escaping quote")
}

test "Profile ownership scoping hides other users' profiles" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-scope")
  val other = newUser("prof-scope-other")
  val mine = mustProfile(
    addProfile(CloudAgents.Pg.personalScope(me), "mine", "", "full", "all", [], [], [], [], "all", [])
  )
  val theirs = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(other),
      "theirs",
      "",
      "full",
      "all",
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )

  val myList = mustProfiles(listProfiles(CloudAgents.Pg.personalScope(me)))
  assertEqualInt(myList.length.toInt(), 1, "only my profile listed")
  assertEqual(myList[0].id, mine.id, "listed profile is mine")

  match getProfile(theirs.id, CloudAgents.Pg.personalScope(me)) {
    case Ok(Some(_)) -> assertTrue(false, "cannot read another user's profile")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqualInt(
    mustRows(
      updateProfile(
        theirs.id,
        CloudAgents.Pg.personalScope(me),
        "x",
        "",
        "full",
        "all",
        [],
        [],
        [],
        [],
        "all",
        []
      )
    ),
    0,
    "cannot update another user's profile"
  )
  assertEqualInt(
    mustRows(deleteProfile(theirs.id, CloudAgents.Pg.personalScope(me))),
    0,
    "cannot delete another user's profile"
  )
}

test "Selected-mode profile injects only its granted credentials" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-inject")
  val userId = me
  mustPutCredential(userId, "GITHUB_TOKEN", "ghp_secret")
  mustPutCredential(userId, "AWS_KEY", "aws_secret")
  mustPutCredential(userId, "OPENAI_KEY", "oai_secret")

  // 'selected' profile grants only GITHUB_TOKEN.
  val locked = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "gh-only",
      "",
      "none",
      "selected",
      ["GITHUB_TOKEN"],
      [],
      [],
      [],
      "all",
      []
    )
  )
  val injected = mustProfileCreds(decryptedCredentialsForProfile(CloudAgents.Pg.personalScope(userId), locked.id))
  assertEqualInt(injected.length.toInt(), 1, "only the granted credential is injected")
  assertTrue(hasCred(injected, "GITHUB_TOKEN"), "granted credential present")
  assertTrue(not hasCred(injected, "AWS_KEY"), "ungranted credential withheld")

  // 'all' profile injects every credential.
  val allProfile = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "all-creds",
      "",
      "full",
      "all",
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )
  val allInjected = mustProfileCreds(
    decryptedCredentialsForProfile(CloudAgents.Pg.personalScope(userId), allProfile.id)
  )
  assertEqualInt(allInjected.length.toInt(), 3, "all mode injects every credential")

  // No profile (empty id) falls open to all credentials (legacy behaviour).
  val legacy = mustProfileCreds(decryptedCredentialsForProfile(CloudAgents.Pg.personalScope(userId), ""))
  assertEqualInt(legacy.length.toInt(), 3, "empty profile id -> all credentials")

  // Fail closed (#231): a NON-EMPTY profile id that can't be resolved (deleted
  // profile) injects nothing rather than escalating to every credential.
  val orphaned = mustProfileCreds(
    decryptedCredentialsForProfile(CloudAgents.Pg.personalScope(userId), "does-not-exist")
  )
  assertEqualInt(orphaned.length.toInt(), 0, "unknown profile id -> no credentials (fail closed)")
}

test "Selected-mode profile enables only its granted tools, and fails OPEN for unresolved profiles" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-tools")
  val userId = me

  // 'selected' profile grants only remember + recall. Read back alphabetical
  // (selectProfileToolsSql orders by tool_name ASC, mirroring
  // selectProfileCredentialsSql), not insertion order.
  val locked = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "notes-only",
      "",
      "full",
      "all",
      [],
      [],
      [],
      [],
      "selected",
      ["remember", "recall"]
    )
  )
  match enabledToolsForProfile(CloudAgents.Pg.personalScope(userId), locked.id) {
    case Ok(v) -> assertEqual(v, "recall,remember", "selected mode joins the granted tool names, alphabetical")
    case Err(e) -> assertTrue(false, "enabledToolsForProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // 'all' mode -> no restriction (empty string sentinel).
  val allProfile = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "every-tool",
      "",
      "full",
      "all",
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )
  match enabledToolsForProfile(CloudAgents.Pg.personalScope(userId), allProfile.id) {
    case Ok(v) -> assertEqual(v, "", "'all' mode -> no restriction")
    case Err(e) -> assertTrue(false, "enabledToolsForProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // No profile (empty id) -> no restriction (unlike credentials, this isn't a
  // security boundary in v1).
  match enabledToolsForProfile(CloudAgents.Pg.personalScope(userId), "") {
    case Ok(v) -> assertEqual(v, "", "empty profile id -> no restriction")
    case Err(e) -> assertTrue(false, "enabledToolsForProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // Fail OPEN (deliberately unlike decryptedCredentialsForProfile above): a
  // NON-EMPTY profile id that can't be resolved (deleted profile) still
  // resolves to "no restriction" rather than disabling every tool.
  match enabledToolsForProfile(CloudAgents.Pg.personalScope(userId), "does-not-exist") {
    case Ok(v) -> assertEqual(v, "", "unknown profile id -> no restriction (fail open)")
    case Err(e) -> assertTrue(false, "enabledToolsForProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

test "Network policy resolves and fails closed for unknown profiles" {
  if not live() {
    return
  }
  val me = freshUser("prof-profile-network")
  val userId = me
  val isolated = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "isolated",
      "",
      "none",
      "all",
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )

  match profileNetworkPolicy(CloudAgents.Pg.personalScope(userId), isolated.id) {
    case Ok(p) -> assertEqual(p, "none", "profile network policy read back")
    case Err(e) -> assertTrue(false, "policy read failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  // Empty profile -> full (legacy default); unknown non-empty -> none (closed).
  match profileNetworkPolicy(CloudAgents.Pg.personalScope(userId), "") {
    case Ok(p) -> assertEqual(p, "full", "no profile -> full network")
    case Err(e) -> assertTrue(false, "policy read failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match profileNetworkPolicy(CloudAgents.Pg.personalScope(userId), "does-not-exist") {
    case Ok(p) -> assertEqual(p, "none", "unknown profile -> isolated (fail closed)")
    case Err(e) -> assertTrue(false, "policy read failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}
