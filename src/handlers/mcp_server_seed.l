//! Seeds a curated default MCP server catalog into a brand-new user's
//! library (see seed/mcp-servers/*.json), following the exact same
//! gating/never-overwrite/best-effort shape as CloudAgents.LibrarySeed
//! (subagents/skills) — see that file's module doc comment for the
//! reasoning shared by all three seed kinds. The one real difference: an
//! MCP server is a structured record (transport/command/args/url/env/
//! enabled), not a markdown-with-frontmatter file, so each seed entry here
//! is one small hand-authored JSON file instead, decoded directly via
//! @generate(Json) rather than CloudAgents.LibrarySeed's hand-rolled
//! frontmatter scanning.
//!
//! Every credential-requiring seed entry (github.json) ships with
//! `"enabled": "0"` — CloudAgents.Repository.mcpServersForProfile excludes a
//! disabled server from every profile's container injection, so a server
//! that needs a credential the user hasn't granted yet is present in their
//! library (visible, editable via the normal MCP server API) but never
//! actually spun up in a container until they flip it on. Everything else
//! (fetch, context7) needs no credential at all and ships enabled;
//! playwright ships disabled too, not for a credential reason but because
//! it spawns a real browser process and downloads Chromium on first use —
//! a deliberate opt-in rather than a silent default for every session.
//!
//! A credential-requiring server's env (or, for a url-transport server, its
//! headers — see below) references the credential by name (e.g.
//! "GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}" / "Authorization=Bearer
//! ${GITHUB_TOKEN}") — the `${VAR}` is expanded against the container's real
//! environment by docker/inject-library.sh's envsubst pass at injection
//! time, never stored as a literal secret here (mcp_server_env/
//! mcp_server_headers are deliberately non-secret config only, see
//! CloudAgents.Db.mcpServerEnvSchemaSql's/mcpServerHeadersSchemaSql's doc
//! comments); the actual GITHUB_TOKEN value flows in separately through the
//! existing per-user credential vault, exactly like every other
//! credential-grant.
//!
//! `github.json` (#768) is a url-transport server rather than the old
//! `npx @modelcontextprotocol/server-github` stdio command — that npm
//! package is deprecated upstream. It points at GitHub's own hosted MCP
//! endpoint (`https://api.githubcopilot.com/mcp/`) with an `Authorization:
//! Bearer ${GITHUB_TOKEN}` header instead, which is what the `headers` field
//! (CloudAgents.Db.mcpServerHeadersSchemaSql, docker/inject-library.sh's
//! url-transport rendering) exists to carry.
package CloudAgents.McpServerSeed

import Std.Core
import Std.File
import CloudAgents.Library
import CloudAgents.Repository
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString

// Own tiny FFI surface for UTF-8 decoding, mirroring
// CloudAgents.LibrarySeed's bytesToUtf8 (see its doc comment on
// Std.File.read vs readBytes) rather than importing another package's.
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func bytesToUtf8(enc: in Encoding, bytes: in slice[Byte]): String = ""

// Mirrors src/handlers/library.l's maxMcpFieldLen/maxMcpArgCount/
// maxMcpEnvCount by value, not import — see CloudAgents.LibrarySeed's own
// maxDescriptionLen/maxBodyLen/maxModelLen doc comment for why a
// cross-package `pub val` is avoided in this codebase (#750: it compiles
// clean but crashes every caller at runtime).
val maxMcpFieldLen = 4096

val maxMcpArgCount = 64

val maxMcpEnvCount = 64

val maxMcpHeaderCount = 64

/// Directory the seed MCP server .json files are read from, mirroring
/// CloudAgents.LibrarySeed's env-override convention (deploy/api.Dockerfile
/// COPYs seed/ into the image alongside the compiled app, so the default
/// resolves correctly there).
pub func seedMcpServersDir(): String {
  val p = Env.GetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR")
  if DotNetString.IsNullOrEmpty(p) {
    return "seed/mcp-servers"
  }
  return p
}

/// The curated, hand-reviewed default MCP server set — deliberately a fixed
/// list rather than a directory scan, same reasoning as
/// CloudAgents.LibrarySeed.defaultSubagentNames.
pub func defaultMcpServerNames(): slice[String] {
  var acc: slice[String] = []
  acc = acc.append("context7")
  acc = acc.append("fetch")
  acc = acc.append("github")
  acc = acc.append("playwright")
  return acc
}

@generate(Json)
pub record ParsedMcpServer {
  pub name: String
  pub transport: String
  pub command: String
  pub args: slice[String]
  pub url: String
  pub env: slice[String]
  pub enabled: String
  // "Name=Value" HTTP header entries — only meaningful for transport "url"
  // (#768). Every seed/mcp-servers/*.json file must include this key: as
  // with every other field on this record, `@generate(Json)`'s derived
  // fromJson requires it present regardless of any Lyric-level default.
  pub headers: slice[String]
}

func readSeedMcpServer(name: in String): Option[ParsedMcpServer] {
  val path = seedMcpServersDir() + "/" + name + ".json"
  val bytes = match Std.File.readBytes(path) {
    case Ok(b) -> b
    case Err(_) -> return None
  }
  match ParsedMcpServer.fromJson(bytesToUtf8(utf8Encoding(), bytes.toArray())) {
    case Ok(p) -> return Some(value = p)
    case Err(_) -> return None
  }
}

/// Mirrors validateSaveMcpServer's bounds (src/handlers/library.l) by hand,
/// the same reasoning as CloudAgents.LibrarySeed's
/// isWithinSubagentBounds/isWithinSkillBounds (#750) — a seeded insert goes
/// straight through CloudAgents.Repository, bypassing that handler-level
/// validation entirely.
func isWithinMcpServerBounds(parsed: in ParsedMcpServer): Bool {
  if not CloudAgents.Library.isValidMcpTransport(parsed.transport) {
    return false
  }
  if parsed.enabled != "0" and parsed.enabled != "1" {
    return false
  }
  if parsed.transport == "stdio" {
    if parsed.command.length.toInt() == 0 or parsed.command.length.toInt() > maxMcpFieldLen {
      return false
    }
    if parsed.args.length.toInt() > maxMcpArgCount {
      return false
    }
  } else {
    if parsed.url.length.toInt() == 0 or parsed.url.length.toInt() > maxMcpFieldLen {
      return false
    }
  }
  if parsed.env.length.toInt() > maxMcpEnvCount {
    return false
  }
  if parsed.headers.length.toInt() > maxMcpHeaderCount {
    return false
  }
  var i = 0
  while i < parsed.args.length.toInt() {
    if parsed.args[i].length.toInt() > maxMcpFieldLen {
      return false
    }
    i = i + 1
  }
  var ei = 0
  while ei < parsed.env.length.toInt() {
    val entry = parsed.env[ei]
    // Control-char check mirrors isValidMcpEnvEntry's #782 fix — kept in
    // sync per this function's own doc comment.
    if entry.length.toInt() == 0 or entry.length.toInt() > maxMcpFieldLen or not entry.contains("=") or entry.substring(0, 1) == "=" or CloudAgents.Text.containsControlChar(entry) {
      return false
    }
    ei = ei + 1
  }
  var hi = 0
  while hi < parsed.headers.length.toInt() {
    val entry = parsed.headers[hi]
    // Same bounds/shape/control-char check as env above, reused for headers.
    if entry.length.toInt() == 0 or entry.length.toInt() > maxMcpFieldLen or not entry.contains("=") or entry.substring(0, 1) == "=" or CloudAgents.Text.containsControlChar(entry) {
      return false
    }
    hi = hi + 1
  }
  return true
}

/// Best-effort: give a user with no MCP servers at all the curated default
/// set. Same never-fails / empty-library-gated / per-name-double-checked
/// shape as CloudAgents.LibrarySeed.seedDefaultSubagentsIfEmpty — see its
/// doc comment for the full reasoning (a missing/misconfigured seed
/// directory, a malformed seed file, or a DB hiccup on any one item just
/// means fewer/zero seeded servers, same as an empty library today).
pub func seedDefaultMcpServersIfEmpty(userId: in String): Unit {
  val existing = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> return ()
  }
  if existing.length.toInt() > 0 {
    return ()
  }
  val names = defaultMcpServerNames()
  var i = 0
  while i < names.length.toInt() {
    match readSeedMcpServer(names[i]) {
      case Some(parsed) -> {
        if CloudAgents.Library.isValidLibraryName(parsed.name) and isWithinMcpServerBounds(parsed) {
          match CloudAgents.Repository.mcpServerIdByName(userId, parsed.name) {
            case Ok(None) -> {
              match CloudAgents.Repository.addMcpServer(
                userId, parsed.name, parsed.transport, parsed.command, parsed.args, parsed.url, parsed.env,
                parsed.enabled, parsed.headers
              ) {
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
