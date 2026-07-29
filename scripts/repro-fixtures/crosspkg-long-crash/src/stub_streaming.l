package CloudAgents.Streaming

import Std.Core

pub func nextPollMs(current: in Int, maxMs: in Int): Int {
  return current
}

pub func outputDelta(logs: in String, offset: in Int): String {
  return ""
}

pub func sseArtifactReported(id: in String, fileName: in String, mimeType: in String): String {
  return ""
}

pub func sseKeepalive(): String {
  return ": keepalive\n\n"
}

pub func sseNotification(id: in String, level: in String, summary: in String): String {
  return ""
}

pub func ssePermissionRequest(id: in String, toolName: in String, inputJson: in String): String {
  return ""
}

pub func sseProgressUpdate(summary: in String, percentComplete: in String): String {
  return ""
}

pub func sseSecretRequest(id: in String, name: in String, reason: in String): String {
  return ""
}

pub func sseUserQuestion(id: in String, question: in String, optionsJson: in String): String {
  return ""
}

pub func toSseChunk(line: in String): String {
  return "data: " + line + "\n\n"
}
