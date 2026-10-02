package CloudAgents.Db

import Std.Core

// Valid `volume:path` binds: Lyric.Docker 0.7+ rejects malformed ones with a
// PreconditionViolated before any request is sent, which would stop this
// fixture short of the code under test.
pub func homeVolumeBindFor(userId: in String, harness: in String): String {
  return "repro-home:/home/claude-user"
}

pub func workspaceVolumeBindFor(userId: in String, sessionId: in String): String {
  return "repro-workspace:/workspace"
}
