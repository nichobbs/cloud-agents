//! Seeds a brand-new user's subagent and skill library from hand-curated
//! default sets (see seed/subagents/*.md and seed/skills/*/SKILL.md), so a
//! fresh sign-in isn't staring at an empty library. Both seed sets are
//! deliberately fixed lists (defaultSubagentNames/defaultSkillNames below),
//! not a scan of this repo's own .claude/ directory: .claude/agents and
//! .claude/skills are this repo's own Claude Code tooling config, and most
//! of .claude/skills specifically assumes the oh-my-claudecode plugin's own
//! runtime (a `omc`-branded CLI, tmux orchestration, `.omc/`-path
//! conventions) that no runner container image installs — not generically
//! portable content for an arbitrary end user's session. seed/subagents
//! holds every .claude/agents/*.md entry EXCEPT qa-tester (its whole
//! methodology is tmux-based), each with its OMC/ralplan-specific mechanics
//! (`.omc/plans/` paths, `oh-my-claudecode:*` cross-agent Task calls, the
//! ralplan consensus-review mode) edited out — see the diff against
//! .claude/agents/ for exactly what changed per file. seed/skills holds
//! freshly authored content instead, since none of .claude/skills was
//! portable to begin with. CloudAgents.OAuth calls
//! seedDefaultLibraryIfEmpty on every successful sign-in; each half is a
//! no-op once the user already has any subagent/skill at all, seeded or
//! user-authored.
package CloudAgents.LibrarySeed

import Std.Core
import Std.File
import CloudAgents.Library
import CloudAgents.Repository
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString

// `Std.File.read` (the String-returning read) is documented in
// docs/lyric/stdlib.md but, like `.toUpperCase()`/`.replace()`/`unwrapResult()`
// elsewhere in this toolchain (docs/lyric/gotchas.md), compiles but dies at
// runtime here ("unsupported method 'read' on the receiver type") — nothing
// in this codebase actually exercises it, unlike the confirmed-working
// `Std.File.readBytes`/`writeBytes`/`createDir` (see
// CloudAgents.Callbacks). Reading a seed file therefore goes through
// `readBytes` + a private byte->UTF-8-string decode, mirroring
// CloudAgents.Crypto's own private `utf8()`/`encGetString` pair rather than
// importing another package's — each package here owns its own tiny FFI
// surface for this instead of sharing one.
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func bytesToUtf8(enc: in Encoding, bytes: in slice[Byte]): String = ""

/// Directory the seed subagent .md files are read from, mirroring
/// CloudAgents.Repository.artifactsBaseDir's env-override convention
/// (CLOUD_AGENTS_SEED_SUBAGENTS_DIR when set, else a relative default in the
/// working directory — deploy/api.Dockerfile COPYs seed/ into the image
/// alongside the compiled app, so the default resolves correctly there).
pub func seedSubagentsDir(): String {
  val p = Env.GetEnvironmentVariable("CLOUD_AGENTS_SEED_SUBAGENTS_DIR")
  if DotNetString.IsNullOrEmpty(p) {
    return "seed/subagents"
  }
  return p
}

/// The curated, hand-reviewed default subagent set — deliberately a fixed
/// list rather than a directory scan, so what ships to every new user is
/// always an explicit, reviewed set and adding to it is a visible diff here,
/// not a side effect of dropping a file in seed/subagents. This is every
/// .claude/agents/*.md entry in this repo EXCEPT qa-tester, whose entire
/// methodology assumes a tmux binary no runner container image installs.
pub func defaultSubagentNames(): slice[String] {
  var acc: slice[String] = []
  acc = acc.append("analyst")
  acc = acc.append("architect")
  acc = acc.append("code-reviewer")
  acc = acc.append("code-simplifier")
  acc = acc.append("critic")
  acc = acc.append("debugger")
  acc = acc.append("designer")
  acc = acc.append("document-specialist")
  acc = acc.append("executor")
  acc = acc.append("explore")
  acc = acc.append("git-master")
  acc = acc.append("planner")
  acc = acc.append("scientist")
  acc = acc.append("security-reviewer")
  acc = acc.append("tracer")
  acc = acc.append("verifier")
  acc = acc.append("writer")
  return acc
}

pub record ParsedSubagent {
  pub name: String
  pub description: String
  pub model: String
  pub systemPrompt: String
}

/// First line starting at or after `from` whose content is `line`, scanning
/// by hand with CloudAgents.Text.indexOfFrom/.substring — `.split`/`.trim`
/// are not reliably confirmed working at runtime in this toolchain
/// (docs/lyric/gotchas.md), so frontmatter parsing avoids both entirely.
func frontmatterField(frontmatter: in String, key: in String): String {
  val prefix = key + ": "
  val prefixLen = prefix.length.toInt()
  val len = frontmatter.length.toInt()
  var start = 0
  while start < len {
    val nl = CloudAgents.Text.indexOfFrom(frontmatter, "\n", start)
    val lineEnd = if nl < 0 { len } else { nl }
    val lineLen = lineEnd - start
    if lineLen >= prefixLen and frontmatter.substring(start, prefixLen) == prefix {
      return frontmatter.substring(start + prefixLen, lineLen - prefixLen)
    }
    start = lineEnd + 1
  }
  return ""
}

/// Parses a seed subagent file: `---\n`-delimited YAML-ish frontmatter (only
/// `name`/`description`/`model` are read; any other key, e.g. `level` or
/// `disallowedTools`, is ignored) followed by the system prompt body. Not a
/// general Markdown-frontmatter parser — deliberately narrow, matching only
/// the exact hand-curated shape seed/subagents/*.md files are written in,
/// with no claim to handle arbitrary frontmatter shapes correctly.
pub func parseSubagentMarkdown(content: in String): Option[ParsedSubagent] {
  val openMarker = "---\n"
  val closeMarker = "\n---\n"
  val openLen = openMarker.length.toInt()
  val contentLen = content.length.toInt()
  if contentLen < openLen or content.substring(0, openLen) != openMarker {
    return None
  }
  val closeIdx = CloudAgents.Text.indexOfFrom(content, closeMarker, openLen)
  if closeIdx < 0 {
    return None
  }
  val frontmatter = content.substring(openLen, closeIdx - openLen)
  val bodyStart = closeIdx + closeMarker.length.toInt()
  val body = if bodyStart < contentLen { content.substring(bodyStart, contentLen - bodyStart) } else { "" }
  val name = frontmatterField(frontmatter, "name")
  val description = frontmatterField(frontmatter, "description")
  val model = frontmatterField(frontmatter, "model")
  if name.length.toInt() == 0 or description.length.toInt() == 0 or body.length.toInt() == 0 {
    return None
  }
  return Some(value = ParsedSubagent(name = name, description = description, model = model, systemPrompt = body))
}

func readSeedSubagent(name: in String): Option[ParsedSubagent] {
  val path = seedSubagentsDir() + "/" + name + ".md"
  match Std.File.readBytes(path) {
    case Ok(bytes) -> return parseSubagentMarkdown(bytesToUtf8(utf8Encoding(), bytes))
    case Err(_) -> return None
  }
}

/// Best-effort: give a user with no subagents at all the curated default
/// set. Never fails the caller — a missing/misconfigured seed directory, a
/// malformed seed file, or a DB hiccup on any one item just means fewer (or
/// zero) seeded subagents, same as an empty library today. Gated on the
/// user's subagent library currently being completely empty, not on a
/// per-name check, so a user who deliberately deletes every seeded subagent
/// down to zero doesn't have them silently reappear on a later sign-in — and
/// re-checked per name below anyway, for the rare case a request races this
/// same call twice.
pub func seedDefaultSubagentsIfEmpty(userId: in String): Unit {
  val existing = match CloudAgents.Repository.listSubagents(userId) {
    case Ok(s) -> s
    case Err(_) -> return ()
  }
  if existing.length.toInt() > 0 {
    return ()
  }
  val names = defaultSubagentNames()
  var i = 0
  while i < names.length.toInt() {
    match readSeedSubagent(names[i]) {
      case Some(parsed) -> {
        if CloudAgents.Library.isValidLibraryName(parsed.name) {
          match CloudAgents.Repository.subagentIdByName(userId, parsed.name) {
            case Ok(None) -> {
              match CloudAgents.Repository.addSubagent(userId, parsed.name, parsed.description, parsed.systemPrompt, parsed.model) {
                case Ok(_) -> ()
                case Err(_) -> ()
              }
            }
            case Ok(Some(_)) -> ()
            case Err(_) -> ()
          }
        }
      }
      case None -> ()
    }
    i = i + 1
  }
}

// ─── Skills ─────────────────────────────────────────────────────────────────
//
// Skills are freshly authored here (seed/skills/*/SKILL.md), not lifted from
// .claude/skills/ at all — every entry there is oh-my-claudecode-plugin
// content (see the module doc comment above), so there was nothing portable
// to curate down from. These five are harness-agnostic, self-contained
// instructions (commit style, PR descriptions, debugging method, a pre-submit
// self-review checklist, and dependency vetting) that need nothing beyond
// the tools any coding session already has.

/// Directory the seed skill folders are read from (each holds a SKILL.md),
/// mirroring seedSubagentsDir's env-override convention.
pub func seedSkillsDir(): String {
  val p = Env.GetEnvironmentVariable("CLOUD_AGENTS_SEED_SKILLS_DIR")
  if DotNetString.IsNullOrEmpty(p) {
    return "seed/skills"
  }
  return p
}

/// The curated, hand-authored default skill set — see the module doc
/// comment for why this is fresh content rather than anything sourced from
/// .claude/skills/.
pub func defaultSkillNames(): slice[String] {
  var acc: slice[String] = []
  acc = acc.append("conventional-commits")
  acc = acc.append("pr-description")
  acc = acc.append("systematic-debugging")
  acc = acc.append("self-code-review")
  acc = acc.append("dependency-vetting")
  return acc
}

pub record ParsedSkill {
  pub name: String
  pub description: String
  pub body: String
}

/// Same `---\n`-delimited frontmatter shape as parseSubagentMarkdown, but a
/// skill has no `model` field — the whole file (frontmatter stripped) is
/// stored verbatim as the skill body.
pub func parseSkillMarkdown(content: in String): Option[ParsedSkill] {
  val openMarker = "---\n"
  val closeMarker = "\n---\n"
  val openLen = openMarker.length.toInt()
  val contentLen = content.length.toInt()
  if contentLen < openLen or content.substring(0, openLen) != openMarker {
    return None
  }
  val closeIdx = CloudAgents.Text.indexOfFrom(content, closeMarker, openLen)
  if closeIdx < 0 {
    return None
  }
  val frontmatter = content.substring(openLen, closeIdx - openLen)
  val bodyStart = closeIdx + closeMarker.length.toInt()
  val body = if bodyStart < contentLen { content.substring(bodyStart, contentLen - bodyStart) } else { "" }
  val name = frontmatterField(frontmatter, "name")
  val description = frontmatterField(frontmatter, "description")
  if name.length.toInt() == 0 or description.length.toInt() == 0 or body.length.toInt() == 0 {
    return None
  }
  return Some(value = ParsedSkill(name = name, description = description, body = body))
}

func readSeedSkill(name: in String): Option[ParsedSkill] {
  val path = seedSkillsDir() + "/" + name + "/SKILL.md"
  match Std.File.readBytes(path) {
    case Ok(bytes) -> return parseSkillMarkdown(bytesToUtf8(utf8Encoding(), bytes))
    case Err(_) -> return None
  }
}

/// Best-effort: give a user with no skills at all the curated default set.
/// Same never-fails / empty-library-gated / per-name-double-checked shape as
/// seedDefaultSubagentsIfEmpty — see its doc comment for the reasoning.
pub func seedDefaultSkillsIfEmpty(userId: in String): Unit {
  val existing = match CloudAgents.Repository.listSkills(userId) {
    case Ok(s) -> s
    case Err(_) -> return ()
  }
  if existing.length.toInt() > 0 {
    return ()
  }
  val names = defaultSkillNames()
  var i = 0
  while i < names.length.toInt() {
    match readSeedSkill(names[i]) {
      case Some(parsed) -> {
        if CloudAgents.Library.isValidLibraryName(parsed.name) {
          match CloudAgents.Repository.skillIdByName(userId, parsed.name) {
            case Ok(None) -> {
              match CloudAgents.Repository.addSkill(userId, parsed.name, parsed.description, parsed.body) {
                case Ok(_) -> ()
                case Err(_) -> ()
              }
            }
            case Ok(Some(_)) -> ()
            case Err(_) -> ()
          }
        }
      }
      case None -> ()
    }
    i = i + 1
  }
}

/// Best-effort: seed both the default subagent and skill sets for a
/// brand-new sign-in. Each is independently gated on its own table being
/// empty (see the individual functions), so a user who has, say, subagents
/// but no skills yet — because they deleted every seeded skill — still gets
/// nothing re-added for skills while subagents are left untouched, and vice
/// versa.
pub func seedDefaultLibraryIfEmpty(userId: in String): Unit {
  seedDefaultSubagentsIfEmpty(userId)
  seedDefaultSkillsIfEmpty(userId)
}
