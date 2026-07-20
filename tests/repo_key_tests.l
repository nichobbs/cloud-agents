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

test "repoKeyOf drops an explicit port but keeps the scp-style separator (#574)" {
  val want = "github.com/nichobbs/cloud-agents"
  assertEqual(repoKeyOf("ssh://git@github.com:2222/nichobbs/cloud-agents.git"), want, "ssh:// with a port")
  assertEqual(repoKeyOf("https://github.com:443/nichobbs/cloud-agents"), want, "https with a port")
  // The scp-style colon (followed by a path, not digits) still becomes '/'.
  assertEqual(repoKeyOf("git@github.com:nichobbs/cloud-agents.git"), want, "scp-style colon is not a port")
}

test "repoKeyOf treats a numeric scp path segment as a path, not a port (#585)" {
  // scp-style has no port: a numeric first segment is a real owner/group id
  // and must be kept, so two distinct numeric-owner repos don't collide.
  assertEqual(repoKeyOf("git@gitlab.example:1234/repo.git"), "gitlab.example/1234/repo", "numeric scp owner is kept")
  assertTrue(
    repoKeyOf("git@gitlab.example:1234/repo") != repoKeyOf("git@gitlab.example:5678/repo"),
    "different numeric scp owners stay distinct"
  )
  // But a scheme-bearing URL's numeric segment before '/' is still a port.
  assertEqual(
    repoKeyOf("ssh://git@gitlab.example:22/1234/repo"),
    "gitlab.example/1234/repo",
    "URL port dropped, path kept"
  )
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
