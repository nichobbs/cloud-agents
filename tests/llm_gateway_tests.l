//! LLM Gateway tests: streaming detection, error shapes, profile resolution (dual URL/header),
//! explicit credential mapping resolution (fail-fast), and model listing.
@test_module
package CloudAgents.LlmGatewayTests

import Std.Core
import Std.Testing
import Std.Uuid
import Std.Environment
import CloudAgents
import CloudAgents.Auth
import CloudAgents.Crypto
import CloudAgents.Db
import CloudAgents.Harnesses
import CloudAgents.LlmGateway
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Credentials
import CloudAgents.PgStore.Library
import CloudAgents.PgStore.Tenancy
import CloudAgents.Profiles
import CloudAgents.Repository
import CloudAgents.Scope
import CloudAgents.Text
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func bytesToUtf8(enc: in Encoding, bytes: in slice[Byte]): String = ""

func containsStr(haystack: in String, needle: in String): Bool {
  return CloudAgents.Text.indexOfFrom(haystack, needle, 0) >= 0
}

// ── Offline Unit Tests ────────────────────────────────────────────────────────

test "isStreamingRequested correctly identifies streaming flag in JSON" {
  assertTrue(
    isStreamingRequested("{\"model\": \"claude-3-5-sonnet-20241022\", \"stream\": true}"),
    "stream: true"
  )
  assertTrue(
    isStreamingRequested("{\"model\": \"gpt-4o\", \"stream\":true}"),
    "stream:true without space"
  )
  assertTrue(
    isStreamingRequested("{\"model\": \"gpt-4o\", \"stream\": 1}"),
    "stream: 1"
  )
  assertTrue(
    isStreamingRequested("{\"model\": \"gpt-4o\", \"stream\":1}"),
    "stream:1 without space"
  )
  assertFalse(
    isStreamingRequested("{\"model\": \"gpt-4o\", \"stream\": false}"),
    "stream: false"
  )
  assertFalse(
    isStreamingRequested("{\"model\": \"gpt-4o\"}"),
    "missing stream flag"
  )
}

test "anthropicErrorJson formats standard Anthropic error shape and escapes characters" {
  val err = anthropicErrorJson("invalid_request_error", "Missing \"header\"\nand newline")
  assertTrue(
    containsStr(err, "\"type\":\"error\""),
    "contains type:error"
  )
  assertTrue(
    containsStr(err, "\"type\":\"invalid_request_error\""),
    "contains inner error type"
  )
  assertTrue(
    containsStr(err, "Missing \\\"header\\\"\\nand newline"),
    "escapes quotes and newlines"
  )
}

test "openAiErrorJson formats standard OpenAI error shape and escapes characters" {
  val err = openAiErrorJson("Profile 'test' not found", "invalid_request_error", "profile_not_found")
  assertTrue(
    containsStr(err, "\"message\":\"Profile 'test' not found\""),
    "contains message"
  )
  assertTrue(
    containsStr(err, "\"type\":\"invalid_request_error\""),
    "contains type"
  )
  assertTrue(
    containsStr(err, "\"code\":\"profile_not_found\""),
    "contains code"
  )
}

// ── Live Postgres Tests ───────────────────────────────────────────────────────

func live(): Bool {
  val dsn = Std.Environment.getVarOrDefault("LYRIC_CONFIG_DB_CONNECTION_URL", "")
  val migDsn = Std.Environment.getVarOrDefault("CLOUD_AGENTS_MIGRATE_DATABASE_URL", "")
  val ok = dsn.length.toInt() > 0 and migDsn.length.toInt() > 0
  if ok {
    Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but live PG DSN not set"
  )
  println("SKIP: LLM Gateway tests need live PG")
  return false
}

func runMigrations(): Unit {
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

func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return uid
}

func mustProfile(r: in Result[CloudAgents.Repository.Profile, CloudAgents.Db.DbError]): CloudAgents.Repository.Profile {
  return match r {
    case Ok(p) -> p
    case Err(e) -> panic("profile write failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

test "LLM Gateway resolveProfileRef resolves from URL or header, and rejects empty or unknown" {
  if not live() {
    return ()
  }
  runMigrations()

  val uid = newUser("llm-gw-prof")
  val sc = CloudAgents.Pg.personalScope(uid)

  // 1. Create a profile named 'coder'
  val p = mustProfile(
    CloudAgents.PgStore.Library.addProfileWithMappings(
      sc,
      "coder",
      "claude",
      "full",
      "all",
      [],
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )

  // 2. Resolve by profile ID in URL
  val resById = resolveProfileRef(p.id, "", uid)
  assertTrue(resById.isOk, "resolve by ID in URL")
  val profById: CloudAgents.Repository.Profile = resById.unwrapResult()
  assertEqual(p.name, profById.name, "resolved profile name matches")

  // 3. Resolve by profile Name in URL
  val resByName = resolveProfileRef("coder", "", uid)
  assertTrue(resByName.isOk, "resolve by Name in URL")
  val profByName: CloudAgents.Repository.Profile = resByName.unwrapResult()
  assertEqual(p.id, profByName.id, "resolved profile id matches")

  // 4. Resolve by profile Name in Header when URL is empty
  val resByHeader = resolveProfileRef("", "coder", uid)
  assertTrue(resByHeader.isOk, "resolve by Name in Header")
  val profByHeader: CloudAgents.Repository.Profile = resByHeader.unwrapResult()
  assertEqual(p.id, profByHeader.id, "resolved profile id matches")

  // 5. Fail-fast when neither URL nor Header specifies profile
  val resEmpty = resolveProfileRef("", "", uid)
  assertTrue(resEmpty.isErr, "fail-fast on empty profile specification")
  assertTrue(
    containsStr(resEmpty.unwrapError(), "Profile must be specified"),
    "error clarifies dual URL/header requirement"
  )

  // 6. Fail-fast when unknown profile specified
  val resUnknown = resolveProfileRef("non-existent-profile", "", uid)
  assertTrue(resUnknown.isErr, "fail-fast on non-existent profile")
  assertTrue(
    containsStr(resUnknown.unwrapError(), "Profile 'non-existent-profile' not found"),
    "error specifies unknown profile"
  )
}

test "LLM Gateway credential resolution enforces explicit mappings and fails fast without guessing" {
  if not live() {
    return ()
  }
  runMigrations()

  val uid = newUser("llm-gw-creds")
  val sc = CloudAgents.Pg.personalScope(uid)

  // Store credentials in vault under custom account names
  val claudeJsonVal = "{\"claudeAiOauth\":{\"accessToken\":\"test-oauth-token\",\"refreshToken\":\"test-refresh\",\"expiresAt\":2000000000}}"
  val openAiKeyVal = "sk-test-openai-key-12345"
  val anthropicApiKeyVal = "sk-ant-test-key-67890"

  match CloudAgents.PgStore.Credentials.putCredential(CloudAgents.Scope.userScope(uid), "WORK_CLAUDE", claudeJsonVal) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.PgStore.Credentials.putCredential(CloudAgents.Scope.userScope(uid), "PROD_OPENAI", openAiKeyVal) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.PgStore.Credentials.putCredential(CloudAgents.Scope.userScope(uid), "DIRECT_ANTHROPIC", anthropicApiKeyVal) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Profile 1: Mapped WORK_CLAUDE -> CLAUDE_CREDENTIALS_JSON
  val pClaude = mustProfile(
    CloudAgents.PgStore.Library.addProfileWithMappings(
      sc,
      "work-claude-profile",
      "claude",
      "full",
      "selected",
      [],
      [CloudAgents.Repository.CredentialMapping(source = "WORK_CLAUDE", target = "CLAUDE_CREDENTIALS_JSON")],
      [],
      [],
      [],
      "all",
      []
    )
  )

  // Profile 2: Mapped PROD_OPENAI -> OPENAI_API_KEY
  val pOpenAi = mustProfile(
    CloudAgents.PgStore.Library.addProfileWithMappings(
      sc,
      "prod-openai-profile",
      "codex",
      "full",
      "selected",
      [],
      [CloudAgents.Repository.CredentialMapping(source = "PROD_OPENAI", target = "OPENAI_API_KEY")],
      [],
      [],
      [],
      "all",
      []
    )
  )

  // Profile 3: Mapped DIRECT_ANTHROPIC -> ANTHROPIC_API_KEY
  val pAntKey = mustProfile(
    CloudAgents.PgStore.Library.addProfileWithMappings(
      sc,
      "direct-ant-profile",
      "claude",
      "full",
      "selected",
      [],
      [CloudAgents.Repository.CredentialMapping(source = "DIRECT_ANTHROPIC", target = "ANTHROPIC_API_KEY")],
      [],
      [],
      [],
      "all",
      []
    )
  )

  // Profile 4: Profile with NO mappings
  val pEmpty = mustProfile(
    CloudAgents.PgStore.Library.addProfileWithMappings(
      sc,
      "unmapped-profile",
      "claude",
      "full",
      "selected",
      [],
      [],
      [],
      [],
      [],
      "all",
      []
    )
  )

  // Test 1: pClaude resolves to Bearer OAuth token
  val auth1 = resolveAnthropicAuth(pClaude, uid)
  assertTrue(auth1.isOk, "pClaude resolves Anthropic auth")
  val a1: AnthropicAuth = auth1.unwrapResult()
  assertTrue(a1.isBearer, "isBearer is true for OAuth token")
  assertEqual("test-oauth-token", a1.token, "token matches OAuth access token")

  // Test 2: pAntKey resolves to API Key (isBearer = false)
  val auth2 = resolveAnthropicAuth(pAntKey, uid)
  assertTrue(auth2.isOk, "pAntKey resolves Anthropic auth")
  val a2: AnthropicAuth = auth2.unwrapResult()
  assertFalse(a2.isBearer, "isBearer is false for ANTHROPIC_API_KEY")
  assertEqual("sk-ant-test-key-67890", a2.token, "token matches ANTHROPIC_API_KEY")

  // Test 3: pOpenAi resolves to OpenAI key
  val auth3 = resolveOpenAiAuth(pOpenAi, uid)
  assertTrue(auth3.isOk, "pOpenAi resolves OpenAI key")
  val token3: String = auth3.unwrapResult()
  assertEqual("sk-test-openai-key-12345", token3, "token matches OPENAI_API_KEY")

  // Test 4: pEmpty fails fast on Anthropic without guessing or falling back
  val authEmptyAnt = resolveAnthropicAuth(pEmpty, uid)
  assertTrue(authEmptyAnt.isErr, "unmapped profile fails fast on Anthropic auth")
  assertTrue(
    containsStr(authEmptyAnt.unwrapError(), "has no valid credential mapping or grant"),
    "error states missing mapping"
  )

  // Test 5: pEmpty fails fast on OpenAI without guessing or falling back
  val authEmptyOai = resolveOpenAiAuth(pEmpty, uid)
  assertTrue(authEmptyOai.isErr, "unmapped profile fails fast on OpenAI auth")
  assertTrue(
    containsStr(authEmptyOai.unwrapError(), "has no valid credential mapping or grant for 'OPENAI_API_KEY'"),
    "error states missing mapping for OPENAI_API_KEY"
  )
}

test "LLM Gateway listModelsJson produces valid OpenAI format" {
  val json = listModelsJson()
  assertTrue(containsStr(json, "\"object\":\"list\""), "list object")
  assertTrue(containsStr(json, "\"id\":\"claude-3-7-sonnet-20250219\""), "contains claude 3.7")
  assertTrue(containsStr(json, "\"id\":\"gpt-4o\""), "contains gpt-4o")
  assertTrue(containsStr(json, "\"owned_by\":\"anthropic\""), "anthropic owner")
  assertTrue(containsStr(json, "\"owned_by\":\"openai\""), "openai owner")
}
