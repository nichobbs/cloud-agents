@test_module
package CloudAgents.RunnerEnvTests

import Std.Core
import Std.Testing
import CloudAgents.RunnerEnv

test "baseRunnerEnvs emits the seven base vars in order" {
  val envs = baseRunnerEnvs("do the thing", "https://github.com/o/r", "main", "claude", "claude-opus-4-8", "native-123", "sess-456")
  assertEqualInt(envs.length.toInt(), 7, "seven base env vars")
  assertEqual(envs[0], "PROMPT=do the thing", "PROMPT first")
  assertEqual(envs[1], "REPO_URL=https://github.com/o/r", "REPO_URL second")
  assertEqual(envs[2], "BRANCH=main", "BRANCH third")
  assertEqual(envs[3], "HARNESS=claude", "HARNESS fourth")
  assertEqual(envs[4], "MODEL=claude-opus-4-8", "MODEL fifth")
  assertEqual(envs[5], "NATIVE_SESSION_ID=native-123", "NATIVE_SESSION_ID sixth")
  assertEqual(envs[6], "SESSION_ID=sess-456", "SESSION_ID seventh")
}

test "withExtraRepos only appends EXTRA_REPOS when non-empty" {
  val base = baseRunnerEnvs("p", "u", "b", "h", "m", "n", "s")
  val unchanged = withExtraRepos(base, "")
  assertEqualInt(unchanged.length.toInt(), 7, "empty extraRepos adds nothing")

  val withRepos = withExtraRepos(base, "https://github.com/o/extra|main")
  assertEqualInt(withRepos.length.toInt(), 8, "non-empty extraRepos appends one entry")
  assertEqual(withRepos[7], "EXTRA_REPOS=https://github.com/o/extra|main", "EXTRA_REPOS carries the raw value")
}

test "withCredentialEnvs appends one NAME=VALUE per credential, preserving order" {
  val base = baseRunnerEnvs("p", "u", "b", "h", "m", "n", "s")
  val noNames: slice[String] = []
  val noValues: slice[String] = []
  val unchanged = withCredentialEnvs(base, noNames, noValues)
  assertEqualInt(unchanged.length.toInt(), 7, "no credentials adds nothing")

  val names = ["GITHUB_TOKEN", "AWS_KEY"]
  val values = ["ghp_secret", "aws_secret"]
  val withCreds = withCredentialEnvs(base, names, values)
  assertEqualInt(withCreds.length.toInt(), 9, "two credentials append two entries")
  assertEqual(withCreds[7], "GITHUB_TOKEN=ghp_secret", "first credential formatted and in order")
  assertEqual(withCreds[8], "AWS_KEY=aws_secret", "second credential formatted and in order")
  // The base seven vars must survive untouched — a regression here (e.g. an
  // off-by-one, or the credential loop clobbering `envs` instead of
  // appending) would silently corrupt PROMPT/REPO_URL/etc for every run that
  // injects any credential at all.
  assertEqual(withCreds[0], "PROMPT=p", "base vars are untouched by credential injection")
}

test "credential and EXTRA_REPOS env building compose the way createRunnerContainer chains them" {
  // Mirrors the actual call order in CloudAgents.Docker.createRunnerContainer:
  // base vars -> EXTRA_REPOS -> credentials. This is the exact shape #221
  // flagged as untested: the credential-injection call composed with the rest
  // of the env-building pipeline inside the async, cross-package-calling
  // function.
  var envs = baseRunnerEnvs("prompt", "repo", "main", "claude", "model", "", "sess-1")
  envs = withExtraRepos(envs, "https://github.com/o/extra|")
  val names = ["GITHUB_TOKEN"]
  val values = ["ghp_secret"]
  envs = withCredentialEnvs(envs, names, values)

  assertEqualInt(envs.length.toInt(), 9, "7 base + 1 EXTRA_REPOS + 1 credential")
  assertEqual(envs[7], "EXTRA_REPOS=https://github.com/o/extra|", "EXTRA_REPOS lands before credentials, matching createRunnerContainer's own ordering")
  assertEqual(envs[8], "GITHUB_TOKEN=ghp_secret", "credential lands last")
}
