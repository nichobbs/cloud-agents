package CloudAgents.Crypto

import Std.Core

pub union CryptoError {
  case NotConfigured
  case BadKey(message: String)
  case DecryptFailed(message: String)
}
