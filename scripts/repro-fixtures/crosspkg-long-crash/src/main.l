package CloudAgents

import Std.Core
import Web
import CloudAgents.Docker
import extern System.Environment as Env

record ReproHandler {
}

impl Web.StreamingHandler for ReproHandler {
  func streamHandle(req: in Web.Request, w: in Web.ResponseWriter): Unit {
    val result = CloudAgents.Docker.streamSessionMessage("https://github.com/octocat/Hello-World", "master", "hi", "debug-session-id", "claude", "", "", "", "debug-user-id", "", w)
    match result {
      case Ok(_) -> ()
      case Err(e) -> { val _ = Web.writeChunk(w, "ERR: " + e) }
    }
    return ()
  }
}

func main(): Unit {
  var router = Web.create()
  var streaming = Web.emptyStreamingRoutes()
  streaming = Web.addStreamingPost(streaming, "/run", ReproHandler())
  println("Starting UnboxRepro6 server on port 8097...")
  Env.SetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT", "8097")
  Web.startStreaming(router, streaming)
}
