// Pure trampoline into the Lyric-compiled CloudAgents entry point
// (`CloudAgents.Program.main`). This project exists only so the
// already-compiled CloudAgents.dll (and its NuGet-restored dependency
// closure, all copied into bin/ by `lyric build`) can be published as a
// single executable via `dotnet publish` — it must not contain any
// application logic. See docs/BUILD.md "Distribution" and
// .github/workflows/release.yml for the full rationale and the release
// workflow that builds this.
//
// CloudAgents.Program.main() takes no arguments and reads its own argv
// directly (e.g. --port/-p; see src/main.l's parseCommandLine) — nothing
// needs to be threaded through from here.

namespace CloudAgents.Native;

public static class Program
{
    public static void Main(string[] args) => global::CloudAgents.Program.main();
}
