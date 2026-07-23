package CloudAgents.NetworkPolicy

import Std.Core

pub union DockerTransport {
  case Tcp(hostPort: String)
  case Socket
}

pub func callbackApiUrl(): String {
  return "http://127.0.0.1:1"
}

pub func callbackTimeoutOverride(): String {
  return ""
}

pub func callbacksFeatureEnabled(): Bool {
  return false
}

pub func dockerTransportFor(hostPortVar: in Option[String]): DockerTransport {
  return match hostPortVar {
    case Some(hp) -> Tcp(hostPort = hp)
    case None -> Socket
  }
}

pub func networkModeForPolicyWithCallbacks(policy: in String, callbacksEnabled: in Bool): String {
  return "none"
}

pub func proxyEnvForPolicy(policy: in String): slice[String] {
  return []
}
