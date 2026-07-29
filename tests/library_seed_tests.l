@test_module
package CloudAgents.LibrarySeedTests

import Std.Core
import Std.Collections
import Std.File
import Std.Testing
import Std.Uuid
import CloudAgents.LibrarySeed
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// Mirrors src/handlers/library.l's maxDescriptionLen/maxBodyLen by value, not
// import — see library_seed.l's own maxDescriptionLen/maxBodyLen/maxModelLen
// doc comment for why a cross-package `pub val` is avoided in this codebase.
val maxDescriptionLen = 2000

val maxBodyLen = 200000

val maxModelLen = 200

// ── Live-DB plumbing (same pattern as tests/oauth_tests.l) ────────────────────
@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

// Own tiny FFI surface for building the oversized-fixture test below, same
// convention CloudAgents.LibrarySeed itself follows (see its module comment
// on bytesToUtf8) rather than sharing another package's private bindings.
// This direction (String -> UTF-8 bytes via Encoding.GetBytes) is already
// confirmed working in production, not just in a test — CloudAgents.Crypto's
// own private encGetBytes(utf8(), s) is on the hashing/AES hot path.
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func utf8ToBytes(enc: in Encoding, s: in String): slice[Byte] = []

// Std.File.writeBytes actually takes List[Byte], not the slice[Byte]
// docs/lyric/stdlib.md documents — see CloudAgents.Callbacks.sliceBytesToList
// (docs/lyric/gotchas.md's matching entry). Same conversion, duplicated here
// rather than imported since it isn't pub on the Callbacks side either.
func sliceBytesToList(b: in slice[Byte]): List[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < b.length {
    acc.add(b[i])
    i = i + 1
  }
  return acc
}

// Bytes -> string, for reading the real seed files back in this test file
// (mirrors CloudAgents.LibrarySeed's own private bytesToUtf8 — not reused
// directly since it isn't pub, same one-FFI-surface-per-package convention).
@externInstance
@externTarget("System.Text.Encoding.GetString")
func utf8FromBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
}

// ── Pure frontmatter parsing ───────────────────────────────────────────────
test "parseSubagentMarkdown reads name/description/model and keeps the rest of the file as the prompt body" {
  val content = "---\n" + "name: explore\n" + "description: Finds files and code patterns\n" + "model: haiku\n" +
    "level: 3\n" +
    "disallowedTools: Write, Edit\n" +
    "---\n" +
    "\n" +
    "<Agent_Prompt>Find things.</Agent_Prompt>\n"
  match parseSubagentMarkdown(content) {
    case Some(p) -> {
      assertEqual(p.name, "explore", "name parsed")
      assertEqual(p.description, "Finds files and code patterns", "description parsed")
      assertEqual(p.model, "haiku", "model parsed")
      assertTrue(p.systemPrompt.contains("<Agent_Prompt>Find things.</Agent_Prompt>"), "body carries the prompt")
      assertTrue(not p.systemPrompt.contains("disallowedTools"), "unrecognized frontmatter keys are not leaked into the prompt body")
    }
    case None -> assertTrue(false, "expected a parsed subagent")
  }
}

test "parseSubagentMarkdown tolerates a description containing colons and a missing model" {
  val content = "---\n" + "name: security-reviewer\n" +
    "description: Use this agent when: auth, uploads, or payment data are touched.\n" +
    "---\n" +
    "\n" +
    "You are a security specialist.\n"
  match parseSubagentMarkdown(content) {
    case Some(p) -> {
      assertEqual(p.name, "security-reviewer", "name parsed")
      assertEqual(p.description, "Use this agent when: auth, uploads, or payment data are touched.", "colons in the value are kept")
      assertEqual(p.model, "", "missing model defaults to empty, not a crash")
    }
    case None -> assertTrue(false, "expected a parsed subagent")
  }
}

test "parseSubagentMarkdown rejects content with no frontmatter, no closing delimiter, or an empty body" {
  match parseSubagentMarkdown("just a plain prompt, no frontmatter at all") {
    case Some(_) -> assertTrue(false, "should not parse without an opening --- block")
    case None -> ()
  }
  match parseSubagentMarkdown("---\nname: x\ndescription: y\n") {
    case Some(_) -> assertTrue(false, "should not parse without a closing --- block")
    case None -> ()
  }
  match parseSubagentMarkdown("---\nname: x\ndescription: y\n---\n") {
    case Some(_) -> assertTrue(false, "should not parse an empty body")
    case None -> ()
  }
}

test "seedSubagentsDir defaults to seed/subagents and honors CLOUD_AGENTS_SEED_SUBAGENTS_DIR" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "")
  assertEqual(seedSubagentsDir(), "seed/subagents", "default directory")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "/tmp/custom-seed-dir")
  assertEqual(seedSubagentsDir(), "/tmp/custom-seed-dir", "override honored")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "")
}

test "defaultSubagentNames is the fixed curated set, eighteen names, qa-tester excluded" {
  val names = defaultSubagentNames()
  assertEqualInt(names.length.toInt(), 18, "eighteen curated subagents")
  assertEqual(names[0], "analyst", "first entry")
  var foundQaTester = false
  var i = 0
  while i < names.length.toInt() {
    if names[i] == "qa-tester" {
      foundQaTester = true
    }
    i = i + 1
  }
  assertTrue(not foundQaTester, "qa-tester (tmux-only methodology) is deliberately excluded")
}

// ── seedDefaultSubagentsIfEmpty against a live DB and the real repo-root seed files ──
test "seedDefaultSubagentsIfEmpty populates an empty library from the real seed/subagents files, is idempotent, and never overwrites" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "")
  val dbPath = useFreshTestDb("library-seed")
  val userId = "gh-seed-test-user"

  seedDefaultSubagentsIfEmpty(userId)

  val seeded = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(e) -> {
      assertTrue(false, "listSubagents failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      []
    }
  }
  val expectedNames = defaultSubagentNames()
  assertEqualInt(seeded.length.toInt(), expectedNames.length.toInt(), "every curated subagent seeded from the real files")

  // A second call is a no-op: the library is no longer empty, so nothing is
  // re-inserted (row count unchanged).
  seedDefaultSubagentsIfEmpty(userId)
  val afterSecondCall = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(afterSecondCall.length.toInt(), seeded.length.toInt(), "re-seeding an already-populated library is a no-op")

  // Deleting every seeded subagent brings the user back to empty, and a
  // later sign-in should reseed rather than leave them stuck at zero.
  var i = 0
  while i < seeded.length.toInt() {
    match CloudAgents.Repository.deleteSubagent(seeded[i].id, userId) {
      case Ok(_) -> ()
      case Err(e) -> assertTrue(false, "deleteSubagent failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
    i = i + 1
  }
  seedDefaultSubagentsIfEmpty(userId)
  val reseeded = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(reseeded.length.toInt(), expectedNames.length.toInt(), "an emptied library is reseeded on the next call")

  cleanupTestDb(dbPath)
}

test "seedDefaultSubagentsIfEmpty never touches a library the user has already started customizing" {
  val dbPath = useFreshTestDb("library-seed-nonempty")
  val userId = "gh-seed-test-user-2"
  match CloudAgents.Repository.addSubagent(userId, "my-own-agent", "a hand-authored subagent", "do the thing", "sonnet") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "addSubagent failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  seedDefaultSubagentsIfEmpty(userId)

  val subagents = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(subagents.length.toInt(), 1, "a non-empty library is left exactly as the user made it")
  assertEqual(subagents[0].name, "my-own-agent", "the user's own subagent is untouched")

  cleanupTestDb(dbPath)
}

// ── Skills: pure parsing ───────────────────────────────────────────────────
test "parseSkillMarkdown reads name/description and keeps the rest of the file as the body" {
  val content = "---\n" + "name: conventional-commits\n" +
    "description: Write clear commit messages\n" +
    "---\n" +
    "\n" +
    "Use conventional commit format.\n"
  match parseSkillMarkdown(content) {
    case Some(s) -> {
      assertEqual(s.name, "conventional-commits", "name parsed")
      assertEqual(s.description, "Write clear commit messages", "description parsed")
      assertTrue(s.body.contains("Use conventional commit format."), "body carries the instructions")
    }
    case None -> assertTrue(false, "expected a parsed skill")
  }
}

test "parseSkillMarkdown rejects content with no frontmatter, no closing delimiter, or an empty body" {
  match parseSkillMarkdown("no frontmatter here") {
    case Some(_) -> assertTrue(false, "should not parse without an opening --- block")
    case None -> ()
  }
  match parseSkillMarkdown("---\nname: x\ndescription: y\n---\n") {
    case Some(_) -> assertTrue(false, "should not parse an empty body")
    case None -> ()
  }
}

test "seedSkillsDir defaults to seed/skills and honors CLOUD_AGENTS_SEED_SKILLS_DIR" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR", "")
  assertEqual(seedSkillsDir(), "seed/skills", "default directory")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR", "/tmp/custom-skills-dir")
  assertEqual(seedSkillsDir(), "/tmp/custom-skills-dir", "override honored")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR", "")
}

test "defaultSkillNames is the fixed curated set of five" {
  val names = defaultSkillNames()
  assertEqualInt(names.length.toInt(), 5, "five curated skills")
  assertEqual(names[0], "conventional-commits", "first entry")
}

// ── seedDefaultSkillsIfEmpty against a live DB and the real repo-root seed files ──
test "seedDefaultSkillsIfEmpty populates an empty library from the real seed/skills files, is idempotent, and never overwrites" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR", "")
  val dbPath = useFreshTestDb("library-seed-skills")
  val userId = "gh-seed-test-user-skills"

  seedDefaultSkillsIfEmpty(userId)

  val seeded = match CloudAgents.Repository.listSkills(userId) {
    case Ok(s) -> s
    case Err(e) -> {
      assertTrue(false, "listSkills failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      []
    }
  }
  val expectedNames = defaultSkillNames()
  assertEqualInt(seeded.length.toInt(), expectedNames.length.toInt(), "every curated skill seeded from the real files")

  seedDefaultSkillsIfEmpty(userId)
  val afterSecondCall = match CloudAgents.Repository.listSkills(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(afterSecondCall.length.toInt(), seeded.length.toInt(), "re-seeding an already-populated library is a no-op")

  cleanupTestDb(dbPath)
}

test "seedDefaultSkillsIfEmpty never touches a library the user has already started customizing" {
  val dbPath = useFreshTestDb("library-seed-skills-nonempty")
  val userId = "gh-seed-test-user-skills-2"
  match CloudAgents.Repository.addSkill(userId, "my-own-skill", "a hand-authored skill", "do the thing") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "addSkill failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  seedDefaultSkillsIfEmpty(userId)

  val skills = match CloudAgents.Repository.listSkills(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(skills.length.toInt(), 1, "a non-empty library is left exactly as the user made it")
  assertEqual(skills[0].name, "my-own-skill", "the user's own skill is untouched")

  cleanupTestDb(dbPath)
}

test "seedDefaultLibraryIfEmpty seeds both subagents and skills independently" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR", "")
  val dbPath = useFreshTestDb("library-seed-combined")
  val userId = "gh-seed-test-user-combined"

  seedDefaultLibraryIfEmpty(userId)

  val subagents = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  val skills = match CloudAgents.Repository.listSkills(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(subagents.length.toInt(), defaultSubagentNames().length.toInt(), "subagents seeded")
  assertEqualInt(skills.length.toInt(), defaultSkillNames().length.toInt(), "skills seeded")

  cleanupTestDb(dbPath)
}

// ── #750 regression: seeded content is bounds-checked, not trusted blindly ──
func nCharString(n: in Int, ch: in String): String {
  var acc = ""
  var i = 0
  while i < n {
    acc = acc + ch
    i = i + 1
  }
  return acc
}

test "every real seed/subagents and seed/skills file satisfies the library's own length caps (#750)" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR", "")

  val subagentNames = defaultSubagentNames()
  var i = 0
  while i < subagentNames.length.toInt() {
    match Std.File.readBytes(seedSubagentsDir() + "/" + subagentNames[i] + ".md") {
      case Ok(bytes) -> {
        match parseSubagentMarkdown(utf8FromBytes(utf8Encoding(), bytes)) {
          case Some(p) -> {
            assertTrue(p.description.length.toInt() <= maxDescriptionLen, subagentNames[i] + ": description within cap")
            assertTrue(p.systemPrompt.length.toInt() <= maxBodyLen, subagentNames[i] + ": body within cap")
            assertTrue(p.model.length.toInt() <= maxModelLen, subagentNames[i] + ": model within cap")
          }
          case None -> assertTrue(false, subagentNames[i] + ": failed to parse")
        }
      }
      case Err(_) -> assertTrue(false, subagentNames[i] + ": seed file missing")
    }
    i = i + 1
  }

  val skillNames = defaultSkillNames()
  var j = 0
  while j < skillNames.length.toInt() {
    match Std.File.readBytes(seedSkillsDir() + "/" + skillNames[j] + "/SKILL.md") {
      case Ok(bytes) -> {
        match parseSkillMarkdown(utf8FromBytes(utf8Encoding(), bytes)) {
          case Some(p) -> {
            assertTrue(p.description.length.toInt() <= maxDescriptionLen, skillNames[j] + ": description within cap")
            assertTrue(p.body.length.toInt() <= maxBodyLen, skillNames[j] + ": body within cap")
          }
          case None -> assertTrue(false, skillNames[j] + ": failed to parse")
        }
      }
      case Err(_) -> assertTrue(false, skillNames[j] + ": seed file missing")
    }
    j = j + 1
  }
}

test "seedDefaultSubagentsIfEmpty skips a seed file whose description exceeds the library's own cap, instead of inserting it anyway (#750)" {
  val dbPath = useFreshTestDb("library-seed-oversized")
  val tmpDir = "/tmp/cloud-agents-tests-oversized-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match Std.File.createDir(tmpDir) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "failed to create temp seed dir")
  }
  // Only "explore" exists in this fixture directory — every other curated
  // name in defaultSubagentNames() simply won't be found (readBytes Err),
  // which readSeedSubagent already treats as "skip this one", so the test
  // only needs to plant the one oversized file it's actually checking.
  val oversizedDescription = nCharString(maxDescriptionLen + 1, "x")
  val content = "---\n" + "name: explore\n" + "description: " + oversizedDescription + "\n" + "model: haiku\n" +
    "---\n" +
    "\n" +
    "Body text.\n"
  match Std.File.writeBytes(tmpDir + "/explore.md", sliceBytesToList(utf8ToBytes(utf8Encoding(), content))) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "failed to write the oversized fixture file")
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", tmpDir)
  val userId = "gh-seed-test-user-oversized"

  seedDefaultSubagentsIfEmpty(userId)

  val subagents = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(subagents.length.toInt(), 0, "the oversized entry is skipped rather than inserted with a truncated/oversized field")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR", "")
  cleanupTestDb(dbPath)
}
