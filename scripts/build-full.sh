#!/usr/bin/env bash
# build-full.sh — build the complete Cloud Agents server (API + web + docker).
#
# Unlike scripts/verify.sh (which runtime-checks the Docker-independent logic),
# this builds every package, including the Web- and Docker-dependent ones, by
# assembling the lyric-lang workspace the compiler needs:
#
#   * the full Std.Core (Option/Result/List/...) is only available when the
#     compiler can discover the stdlib *sources*, i.e. when the project is built
#     inside the lyric-lang workspace — so we build there;
#   * the in-repo, enhanced Docker library (vendor/lyric-docker) is dropped in
#     over the workspace's copy;
#   * the Std.Time DateTimeOffset/TimeZone contract leak is patched so the
#     stdlib restores (see patches/).
#
# Requirements on PATH: lyric, dotnet (10.x).
# Env: LYRIC_LANG  path to a lyric-lang checkout (default: ../lyric-lang, cloned
#      if absent).
#
# NOTE: this builds (compiles) the project. Running the @test_module suites
# additionally needs the per-package stdlib runtime DLLs, which the standalone
# Lyric install does not ship; see docs/BUILD.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRIC_LANG="${LYRIC_LANG:-$(cd "$REPO_ROOT/.." && pwd)/lyric-lang}"

command -v lyric  >/dev/null || { echo "build-full: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "build-full: 'dotnet' not on PATH" >&2; exit 1; }

if [ ! -d "$LYRIC_LANG/lyric-stdlib/std" ]; then
  echo "==> cloning lyric-lang into $LYRIC_LANG"
  git clone --depth 1 https://github.com/nichobbs/lyric-lang.git "$LYRIC_LANG"
fi

echo "==> applying stdlib contract-leak patch (idempotent)"
git -C "$LYRIC_LANG" apply --reverse --check "$REPO_ROOT/patches/lyric-stdlib-datetimeoffset-leak.patch" 2>/dev/null \
  && echo "    already applied" \
  || git -C "$LYRIC_LANG" apply "$REPO_ROOT/patches/lyric-stdlib-datetimeoffset-leak.patch"

echo "==> applying lyric-auth contract-leak patch (idempotent)"
git -C "$LYRIC_LANG" apply --reverse --check "$REPO_ROOT/patches/lyric-auth-contract-leak.patch" 2>/dev/null \
  && echo "    already applied" \
  || git -C "$LYRIC_LANG" apply "$REPO_ROOT/patches/lyric-auth-contract-leak.patch"

echo "==> demoting tryExtractClaim in Auth.Kernel.Net (out String param — contract synthesis bug)"
# tryExtractClaim(token, claimKey, value: out String) has an out-param that the
# contract synthesizer cannot serialise to JSON.  Demoting it to package-private
# removes it from the exported contract; auth.l's extractClaim wrapper (in the same
# project build) can still call it because Lyric project builds see package-private
# members of sibling packages within the same project.
AUTH_KERNEL_NET="$LYRIC_LANG/lyric-auth/src/_kernel/net/auth_kernel.l"
if [ -f "$AUTH_KERNEL_NET" ] && grep -q '^pub func tryExtractClaim' "$AUTH_KERNEL_NET"; then
  sed -i 's/^pub func tryExtractClaim/func tryExtractClaim/' "$AUTH_KERNEL_NET"
  echo "    demoted tryExtractClaim to package-private"
else
  echo "    tryExtractClaim already package-private or file not found"
fi

echo "==> installing the in-repo Docker library into the workspace"
rm -rf "$LYRIC_LANG/lyric-docker/src"
cp -r "$REPO_ROOT/vendor/lyric-docker/src" "$LYRIC_LANG/lyric-docker/src"

echo "==> building dependency libraries"
for lib in lyric-stdlib lyric-logging lyric-auth lyric-resilience lyric-web lyric-docker; do
  ( cd "$LYRIC_LANG/$lib" && rm -f lyric.lock && lyric build >/dev/null )
  echo "    built $lib"
  # Track whether lyric-resilience rewrites the auth DLL (it depends on lyric-auth and
  # may re-compile it in a different context, producing a corrupt contract for lyric-web).
  AUTH_DLL="$LYRIC_LANG/lyric-auth/bin/Lyric.Auth.dll"
  DLL_SHA="$(sha256sum "$AUTH_DLL" 2>/dev/null | awk '{print $1}' || echo 'missing')"
  echo "    Lyric.Auth.dll SHA after $lib: $DLL_SHA"
  if [ "$lib" = "lyric-auth" ]; then
    echo "==> files produced by lyric-auth build"
    find "$LYRIC_LANG/lyric-auth" -type f \( -name '*.dll' -o -name '*.json' -o -name '*.lock' \) 2>/dev/null | sort | while read -r f; do
      echo "    $(wc -c < "$f") bytes  $f"
    done
    echo "==> diagnosing Lyric.Contract.Auth resource"
    AUTH_DLL="$LYRIC_LANG/lyric-auth/bin/Lyric.Auth.dll"
    DIAG_DIR="$(mktemp -d)"
    cat > "$DIAG_DIR/diag.cs" <<'CSEOF'
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;

var dllPath = Path.GetFullPath(args[0]);
var asm = Assembly.LoadFile(dllPath);
foreach (var name in asm.GetManifestResourceNames()) {
    if (!name.StartsWith("Lyric.Contract.")) continue;
    using var rs = asm.GetManifestResourceStream(name)!;
    var ms = new MemoryStream(); rs.CopyTo(ms);
    var bytes = ms.ToArray();
    var hex16 = BitConverter.ToString(bytes[..Math.Min(16,bytes.Length)]).Replace("-"," ");
    var txt = Encoding.UTF8.GetString(bytes);
    Console.Write($"  [diag] {name}: {bytes.Length}B hex[0:16]=[{hex16}] — ");
    try { JsonDocument.Parse(txt); Console.WriteLine("VALID"); }
    catch (Exception e) { Console.WriteLine($"INVALID: {e.Message}"); }
    // Print full content so we can see every character
    Console.WriteLine($"  [diag] {name} FULL: {txt}");
}
return 0;
CSEOF
    cat > "$DIAG_DIR/diag.csproj" <<'PROJEOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
  </PropertyGroup>
</Project>
PROJEOF
    ( cd "$DIAG_DIR" && dotnet run --project diag.csproj -- "$AUTH_DLL" 2>&1 ) || true
    rm -rf "$DIAG_DIR"
    # Both reflection and PEReader confirm all contracts are valid JSON, yet the
    # Lyric 0.4.5 restore path rejects the DLL.  Clear the pre-built DLL so that
    # lyric-web and downstream builds must compile lyric-auth from source instead
    # of restoring from this DLL.  Building from source bypasses the restore code
    # path entirely; the patched sources should produce a contract the compiler accepts.
    echo "==> clearing lyric-auth/bin (force source build in downstream deps)"
    rm -rf "$LYRIC_LANG/lyric-auth/bin"
  fi
done

echo "==> building the full Cloud Agents project"
WS="$LYRIC_LANG/.cloud-agents-full"
rm -rf "$WS"; mkdir -p "$WS"
cp -r "$REPO_ROOT/src" "$REPO_ROOT/tests" "$WS/"
cat > "$WS/lyric.toml" <<'TOML'
[package]
name = "CloudAgents"
version = "0.1.0"
[features]
default = ["dotnet", "sqlite"]
dotnet  = []
sqlite  = []
[project]
name = "CloudAgents"
output = "single"
output_assembly = "CloudAgents.dll"
[project.packages]
"CloudAgents"              = "src/main.l"
"CloudAgents.SessionStore" = "src/sessions/session_manager.l"
"CloudAgents.Handlers"     = "src/handlers/sessions.l"
"CloudAgents.Interactions" = "src/handlers/interactions.l"
"CloudAgents.Docker"       = "src/docker_manager.l"
"CloudAgents.Db"           = "src/db/db_client.l"
"CloudAgents.Sqlite"       = "src/db/sqlite_driver.l"
"CloudAgents.Repository"   = "src/db/repository.l"
"CloudAgents.Auth"         = "src/handlers/auth.l"
"CloudAgents.Streaming"    = "src/streaming/streaming.l"
[dependencies]
"Lyric.Web"    = { path = "../lyric-web" }
"Lyric.Docker" = { path = "../lyric-docker" }
"Std.Logging"  = { path = "../lyric-logging" }
TOML

( cd "$WS" && lyric build )
echo "==> Full build succeeded"
rm -rf "$WS"
