//! Pure runner env-list assembly, extracted from
//! CloudAgents.Docker.createRunnerContainer so it's unit-testable — invoking
//! ANY function from the async CloudAgents.Docker package via the
//! @test_module harness throws "The signature is incorrect." (a documented
//! Lyric runtime limitation, docs/lyric/gotchas.md), even for a pure leaf
//! function, so a test can't reach this logic while it lives there. A test
//! importing this pure package hits no such limitation — same reasoning as
//! CloudAgents.NetworkPolicy, split out of CloudAgents.Docker for exactly
//! this reason.
//!
//! This package intentionally has no dependency on CloudAgents.Repository
//! (the credential store) or its CredentialValue record: credentials are
//! passed as two parallel name/value slices rather than a shared record type,
//! so this pure package doesn't need to import a later-declared package, and
//! callers never construct another package's record type across a package
//! boundary (docs/lyric/gotchas.md's "package-qualified record construction"
//! entry is about the qualified form specifically, but this sidesteps the
//! whole risk class rather than relying on the unqualified workaround).
package CloudAgents.RunnerEnv

import Std.Core

/// Build the base runner env list, in the order createRunnerContainer has
/// always emitted it. Order is not cosmetic: Docker keeps the LAST value for
/// a repeated key, so anything appended later (EXTRA_REPOS, credentials,
/// proxy vars) can shadow one of these if a credential is ever named the
/// same as a reserved key — see the RESERVED_ENV_NAMES check at the
/// credential-storage boundary (CloudAgents.Credentials), which exists
/// specifically to keep that from happening.
pub func baseRunnerEnvs(
  prompt: in String,
  repoUrl: in String,
  branch: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
): slice[String] {
  return [
    "PROMPT=" + prompt,
    "REPO_URL=" + repoUrl,
    "BRANCH=" + branch,
    "HARNESS=" + harness,
    "MODEL=" + model,
    "NATIVE_SESSION_ID=" + nativeSessionId
  ]
}

/// Append EXTRA_REPOS only when non-empty, so single-repo sessions pass no
/// EXTRA_REPOS at all (matches docker/reconcile-repos.sh's "unset means no
/// extra repos" contract).
pub func withExtraRepos(envs: in slice[String], extraRepos: in String): slice[String] {
  if extraRepos.length > 0 {
    return envs.append("EXTRA_REPOS=" + extraRepos)
  }
  return envs
}

/// Append one "NAME=VALUE" entry per decrypted credential, preserving the
/// order the credential-injection call returned them in. Never logs a value.
/// `names`/`values` are parallel slices (same index = same credential,
/// exactly how the caller builds them off CredentialValue) and must be the
/// same length — the loop is bounded by `names.length`, matching the
/// pre-extraction code this replaces (which indexed a single creds slice the
/// same way).
pub func withCredentialEnvs(envs: in slice[String], names: in slice[String], values: in slice[String]): slice[String] {
  var result = envs
  var i = 0
  while i < names.length {
    result = result.append(names[i] + "=" + values[i])
    i = i + 1
  }
  return result
}
