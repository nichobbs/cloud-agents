package CloudAgents.Sqlite

import Std.Core

pub union DbError {
  case OpenFailed(message: String)
  case ExecFailed(sql: String, message: String)
}

pub func dbErrorMessage(e: in DbError): String {
  return "db error"
}
