package CloudAgents.Db

import Std.Core

pub func homeVolumeBindFor(userId: in String, harness: in String): String {
  return "repro-home:/home/node"
}

pub func workspaceVolumeBindFor(userId: in String, sessionId: in String): String {
  return "repro-workspace:/workspace"
}
