@test_module
package CloudAgents.RepoKeyTests

import Std.Core
import Std.Testing
import CloudAgents.RepoKey

test "repoKeyOf normalizes every common git URL form to host/owner/repo" {
  val want = "github.com/nichobbs/cloud-agents"
  assertEqual(repoKeyOf("https://github.com/nichobbs/cloud-agents.git"), want, "https + .git")
  assertEqual(repoKeyOf("https://github.com/nichobbs/cloud-agents"), want, "https, no .git")
  assertEqual(repoKeyOf("http://github.com/nichobbs/cloud-agents"), want, "http scheme")
  assertEqual(repoKeyOf("git@github.com:nichobbs/cloud-agents.git"), want, "scp-style ssh")
  assertEqual(repoKeyOf("ssh://git@github.com/nichobbs/cloud-agents.git"), want, "ssh:// scheme")
  assertEqual(repoKeyOf("git://github.com/nichobbs/cloud-agents.git"), want, "git:// scheme")
  assertEqual(
    repoKeyOf("https://x-access-token:SECRET@github.com/nichobbs/cloud-agents"),
    want,
    "embedded credentials are stripped"
  )
  assertEqual(repoKeyOf("https://github.com/nichobbs/cloud-agents/"), want, "trailing slash")
  assertEqual(repoKeyOf("https://github.com/nichobbs/cloud-agents.git/"), want, "trailing .git/ slash")
}

test "repoKeyOf lowercases so case never forks a repo's identity" {
  assertEqual(
    repoKeyOf("https://github.com/NicHobbs/Cloud-Agents.git"),
    "github.com/nichobbs/cloud-agents",
    "mixed case normalizes to lowercase"
  )
}

test "repoKeyOf keeps different hosts distinct" {
  assertEqual(repoKeyOf("https://gitlab.com/o/r"), "gitlab.com/o/r", "gitlab host preserved")
  assertTrue(
    repoKeyOf("https://github.com/o/r") != repoKeyOf("https://gitlab.com/o/r"),
    "same owner/repo on different hosts are different keys"
  )
}

test "repoKeyOf returns empty for input with no usable path" {
  assertEqual(repoKeyOf(""), "", "empty input")
  assertEqual(repoKeyOf("https://github.com"), "", "host only, no path")
  assertEqual(repoKeyOf("https://github.com/"), "", "host + trailing slash only")
}
