@test_module
package CloudAgents.LibrarySeedTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.LibrarySeed
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/oauth_tests.l) ────────────────────
@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

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

test "defaultSubagentNames is the fixed curated set, seventeen names, qa-tester excluded" {
  val names = defaultSubagentNames()
  assertEqualInt(names.length.toInt(), 17, "seventeen curated subagents")
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
