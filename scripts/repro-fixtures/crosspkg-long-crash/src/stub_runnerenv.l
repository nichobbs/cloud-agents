package CloudAgents.RunnerEnv

import Std.Core

pub func baseRunnerEnvs(
  prompt: in String,
  repoUrl: in String,
  branch: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
): slice[String] {
  return []
}

pub func withCredentialEnvs(envs: in slice[String], names: in slice[String], values: in slice[String]): slice[String] {
  return envs
}

pub func withExtraRepos(envs: in slice[String], extraRepos: in String): slice[String] {
  return envs
}
