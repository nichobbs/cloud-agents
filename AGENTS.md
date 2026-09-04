# Agent Instructions

This is the canonical file — keep everything here, don't fork the content
into `CLAUDE.md` too. `CLAUDE.md` is a one-line pointer to this file (not a
symlink: symlinks aren't resolved by GitHub's raw-file/contents-API
endpoints or by checkouts without symlink support, so a symlinked
`CLAUDE.md` can silently serve the literal text "AGENTS.md" instead of real
content). This fixes the drift that happened before: `AGENTS.md` was a
separate copy of `CLAUDE.md` and silently fell out of sync when only one
got edited.

## What this repo is

A Lyric application. Lyric is a safety-oriented language targeting .NET 10 (primary) and JVM (Java 21). Syntax is Kotlin/C#/TypeScript-adjacent. It is not TypeScript or Kotlin — read the docs before writing code.

## Installing the Lyric compiler (if `lyric` isn't on PATH)

In a fresh agent session the `lyric` CLI usually isn't installed yet. Install it with:

```sh
curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh | sh
```

or, for a pinned version, download the release tarball directly (adjust the version):

```sh
curl -fsSL -o lyric.tar.gz https://github.com/nichobbs/lyric-lang/releases/download/v0.4.33/lyric-0.4.33-linux-x64.tar.gz
```

**In a Claude Code remote/cloud session**, both of the above go through the session's
GitHub egress proxy, which blocks direct downloads from `github.com/nichobbs/lyric-lang`
release assets (`api.github.com`/`github.com` requests for a repo return 403 "GitHub
access to this repository is not enabled for this session") until that repo is added to
the session's scope — `raw.githubusercontent.com` fetches (e.g. the installer script
itself) are not gated the same way, but the release-asset download inside the script
still is. Add the repo first with the `add_repo` tool (owner `nichobbs`, repo
`lyric-lang`) before running the installer or curling a release tarball. If `add_repo`
(or any other `claude-code-remote`-server tool) fails with "MCP tool call requires
approval" even after the user approves, that's a session-level connection issue with
that MCP server, not a real permission denial — retrying the same call won't fix it;
ask the user to grant access via the Claude GitHub settings UI (claude.ai admin
settings) instead of continuing to retry the tool call.

## Build and run

```sh
lyric restore        # fetch [nuget] dependencies (run before build/test)
lyric build          # compile (discovers lyric.toml from any subdir)
lyric run            # build + execute
lyric test           # run all @test_module files
lyric fmt --write    # format in place (opinionated, no config)
lyric lint           # style checks
lyric check          # type-check without emitting artifacts
lyric prove          # SMT verification on @proof_required packages
```

All commands discover `lyric.toml` by walking up from the working directory. No arguments needed from any subdir.

**`lyric run` finally works against this real project as of v0.4.17 — all
seven upstream bugs found in sequence are now fixed, as of v0.4.19.** Not
specific to this project. Bug 1 (`buildProject` crash,
[lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925)) is
fixed in [v0.4.11](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11);
bug 2 (`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never
resolving, [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980))
is fixed in [v0.4.12](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12);
bug 3 (NuGet-restored zero-arg functions rejected,
[lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004)) is
fixed in [v0.4.14](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.14)
— **and with those fixed, the full project (all 12 packages) builds
successfully, and `scripts/verify.sh` genuinely passes**, both for the
first time. Bug 4 (NuGet dependency DLLs not copied to the output
directory,
[lyric-lang#5066](https://github.com/nichobbs/lyric-lang/issues/5066)) is
fixed in [v0.4.15](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.15);
bug 5 (wrong cross-package field/method metadata tokens — an `async func`
awaiting an unqualified call into a *later*-declared package, this
project's `CloudAgents.Docker` → `Lyric.Docker`, corrupted token
bookkeeping for every package in between,
[lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177)) is
fixed in [v0.4.17](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.17)
— **`scripts/run-api.sh`/`lyric run` now actually starts the API server**,
for the first time in this project's history. At that point it could not
yet survive or correctly answer a real HTTP request — two root-caused
`Lyric.Web` gaps. **Both are now fixed as of the `Lyric.Web` 0.4.26 pin**
(real request dispatch + header access), and `src/main.l` was migrated to
the resulting `Handler`/`Middleware` model, wiring in auth enforcement.
**Genuinely confirmed end-to-end as of 2026-07-15** (not just compiling):
a real running server answered real `curl` requests correctly, and a real
session creation spawned a real Docker container that cloned a real repo
and streamed real output back — see `docs/BUILD.md` "Dependencies" /
"Net effect" for the full verification, including two `Lyric.Docker`
bugs found and fixed along the way (the automated end-to-end test that
nichobbs/cloud-agents#354 asked for still doesn't exist, but the behavior it
was concerned about is now independently confirmed by manual live
verification). Bug 6
(`slice[T].append(x)` — the compiler's own documented idiom for building up
a slice — threw `"unsupported method 'append'"` at runtime unconditionally,
builds fine, failed only when actually called,
[lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244)) is
fixed in [v0.4.18](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.18).
Bug 7 (found while diagnosing the one test case bug 6's fix didn't clear —
a package-scope (top-level) `val` with no explicit type annotation,
initialized to a string literal, crashed `.length` at runtime with
`System.InvalidCastException: Unable to cast object of type 'System.String'
to type 'System.Collections.IList'` — same-package, unqualified, no
cross-package reference needed; root-caused to
`lyric-compiler/msil/codegen.l`'s package-level val/const pre-scan
defaulting an untyped declaration's MSIL type to `MObject` instead of
inferring it from the initializer; filed as
[lyric-lang#5298](https://github.com/nichobbs/lyric-lang/issues/5298); not
a regression, not specific to this project, and distinct from
[lyric-lang#5258](https://github.com/nichobbs/lyric-lang/issues/5258), a
related but different MSIL bug about *cross*-package qualified `pub val`
access) is **fixed in [v0.4.19](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.19)**.
Bug 8 (a local `val` bound before one `await` silently losing its value if
read again after a SECOND, different-callee `await` in the same async
function — no exception, no diagnostic — found while root-causing a
recurring production crash) is filed as
[lyric-lang#6249](https://github.com/nichobbs/lyric-lang/issues/6249) and
**still open as of v0.4.35**; unlike bugs 1–7, it doesn't block build/run/
test, but it DOES need a source-level workaround — see
`src/docker_manager.l`'s doc comments and `docs/lyric/gotchas.md`'s
"Async" section.
Run `./scripts/repro-compiler-bug.sh` to check which bugs your compiler
still has before assuming a local failure needs a local fix. See
`docs/BUILD.md` "Compiler notes" for full detail.

**`lyric test` runs (as of v0.4.15) and fully passes as of v0.4.19 — every
suite in `lyric.toml`'s `[project.tests]` (the authoritative roster; counts
here would go stale as suites are added).** It no longer crashes as of
v0.4.11 (that was bug 1 above, which also hit this entry point), no longer
fails every test outright on a missing `Lyric.Stdlib.dll` as of v0.4.15
(the same underlying fix as bug 4), no longer fails on cross-package field
corruption as of v0.4.17 (bug 5), no longer fails on `slice[T].append()`
as of v0.4.18 (bug 6), and no longer fails on the top-level untyped
`val`'s `.length` as of v0.4.19 (bug 7 — the previously-failing `Test
Handler createSession validation` case read a top-level `val httpsPrefix =
"https://"` via `.length`, exactly bug 7's trigger).
`./scripts/verify.sh` also still genuinely passes. The live-database
suites additionally need the native SQLite library on the loader path —
see `docs/BUILD.md` "Running tests". More runtime gotchas found since
(broken `Instant.now()`, `unwrapResult`-family methods, qualified record
construction) are catalogued in `docs/lyric/gotchas.md` — read it before
writing runtime-executed code.

Source files use `.l` extension. Entry point is `func main(): Unit` in the appropriate package.

## Before writing any Lyric code

Read `docs/lyric/reference.md`. It covers syntax, type system semantics, and the things that look like TypeScript/Kotlin but aren't.

Read `docs/lyric/gotchas.md` before making assumptions.

## Key doc files

| File | When to read |
|------|-------------|
| `docs/lyric/reference.md` | Before writing any Lyric |
| `docs/lyric/stdlib.md` | Before using Std.* imports |
| `docs/lyric/idioms.md` | Canonical patterns — follow these |
| `docs/lyric/gotchas.md` | If something won't compile |
| `src/` | Working code to pattern-match from |

## Project layout

```
src/          # application source (.l files)
tests/        # @test_module files
docs/lyric/   # agent reference docs
lyric.toml    # project manifest
```

## Provenance capture (Testamur §4.1 / ADR-0004; audit WP4)

`CloudAgents.Capture` (`src/capture/stream_json.l`,
`docs/capture-stream-json.md`) is the offline, verifiable **core** of the
runner capture adapter: it parses `claude -p --output-format stream-json`
NDJSON into typed, seq-numbered, **hash-chained** `CaptureEvent`s (verbatim
payloads, malformed lines captured not dropped, resumable across chunks) with a
`verifyChain` tamper check. It does no Docker/DB/HTTP work — it is pure Lyric,
fully unit-tested (`tests/capture_tests.l`).

**Display-render core — built.** `CloudAgents.Capture.Render`
(`src/capture/render.l`, `docs/capture-display-render.md`) is the pure interpret
layer on top of that fidelity core: `displayTextOf`/`renderDisplayText`
reconstruct the visible assistant transcript (assistant `text` blocks only —
`thinking`/`tool_use`/`tool_result` excluded, matching what plain `--print`
showed) from parsed `CaptureEvent`s, and `finalResultText` extracts the terminal
`result` string. It is the piece that makes the runner flip to
`--output-format stream-json` safe — without it, byte-diffing the NDJSON log to
the PWA would show raw JSON. Grounded on **real** captured harness output
(`tests/fixtures/stream-json/`, two live `claude -p --output-format stream-json`
turns, sanitized only for session-identifying ids/paths), fully offline-tested
(`tests/capture_render_tests.l`). **Runner wiring — landed.** The entrypoint flag is flipped
(`docker/entrypoint.sh` adds `--output-format stream-json --verbose` to every
`claude -p` site via a shared `STREAM_JSON_ARGS` array), the poll loop
(`src/docker_manager.l` `streamSessionMessage`) parses each NDJSON delta into
hash-chained `CaptureEvent`s (`renderLogDelta`), persists them
(`appendSessionEvents`, idempotent/best-effort), and streams the reconstructed
visible text to the PWA; the read-back paths (`getRunOutput` /
`getRunOutputFrom` in `handlers/sessions.l`) route the container log through the
same renderer so a reconnecting client sees text, not raw NDJSON. The offline
core (renderer + `renderLogDelta`/`renderFullLog`) is unit-tested; the live
UI-non-regression check (a real container + the `claude` harness) is the manual
end-to-end step. See the spec §6 "LANDED".

**Checkpoint emitter (WP6) — built.** `CloudAgents.CheckpointBridge`
(`src/capture/checkpoint_bridge.l`, `docs/capture-checkpoint.md`) turns a
captured session's `CaptureEvent`s into the Testamur checkpoint format (a
`Session` + `Step`s + terminal `Checkpoint`, content-addressed exactly as the
platform computes them): it verifies the capture chain, reconstructs the
transcript from the event payloads, and delegates the mapping to the reviewed
platform adapter. The "open decision" that gated it is resolved — *copy the
contract now, migrate to a NuGet package later*: `Testamur.CheckpointFormat` is
**vendored verbatim** under `vendor/testamur-checkpoint-format/` (see its
`VENDORED.md`), package names kept identical to upstream so content addresses
match and the NuGet swap is a manifest-only change. A cross-repo drift-guard test
pins that a fixed transcript maps to the exact ids testamur computes. Pure and
offline (`tests/checkpoint_bridge_tests.l`).

Sequenced follow-ups:
- **Runner wiring — landed** (offline core; live UI check pending a Docker host).
  `docker/entrypoint.sh` emits `--output-format stream-json --verbose`, the poll
  loop (`src/docker_manager.l` `streamSessionMessage`) parses each NDJSON delta
  into hash-chained events (`renderLogDelta`), persists them
  (`appendSessionEvents`), and streams the reconstructed visible text; the
  read-back paths (`getRunOutput`/`getRunOutputFrom`) render the log through the
  same seam. The renderer + delta helpers are unit-tested; the live
  UI-non-regression check (a real container + the `claude` harness rendering
  identical visible text to the old `--print` path) is the remaining manual
  end-to-end step, which needs a Docker host.
- **Persistence — store AND endpoint built.** The `session_events` table
  (migration `0030`) + `Repository` accessors (`appendSessionEvents` /
  `sessionEventsAfterSeq`, over `CaptureEvent`, idempotent batch append and an
  exclusive after-seq cursor) are done and live-SQLite tested
  (`docs/session-events-store.md`, `tests/session_events_tests.l`). The
  `GET /api/sessions/{id}/events?after=seq` endpoint (the other half of the WP4
  acceptance) **shipped** — `getSessionEvents` in `src/handlers/interactions.l`,
  routed in `src/main.l`, spec `docs/session-events-endpoint.md` (merged as
  nichobbs/cloud-agents#966). The remaining piece is now cross-repo: the
  **platform-side fetch client** (Testamur's `CaptureFetch` GETs this endpoint,
  maps, and `ingestObjects` into the graph — the deferred transport seam).
- **Graph handoff**: pass the emitted objects to the platform's `GraphIngest`
  (cross-repo; today the emitted objects are the deliverable).
- **Q4 file-change capture — parser + bridge wiring built; contract re-vendored.**
  `CloudAgents.Capture.GitDiff` (`src/capture/git_diff.l`,
  `docs/capture-git-diff.md`) parses `git diff` unified output into
  checkpoint-format `FileDelta`s (new-side hunk ranges + path; add/modify/delete/
  rename/copy/binary), the input a `file_change` step carries. The vendored
  `Adapt` (`vendor/testamur-checkpoint-format/`) was re-vendored from testamur
  #127 to gain `mapStreamJsonWithFileChanges` (agent-origin `file_change` step as
  the checkpoint frontier tip — ADR-0016), and `CheckpointBridge` now exposes
  `emitFromCaptureWithFileChanges` / `emitFromCaptureWithDiff` (the latter parses
  the runner's `git diff HEAD` — its inspect-diff output — into deltas). So a
  captured session + a real workspace diff emits a `file_change`-bearing
  checkpoint, which is what makes Q4 answer on a runner session (Q4 itself proven
  testamur-side on live PG in #127). Empty deltas ⇒ byte-identical content
  addresses (the cross-repo drift-guard test still pins the exact ids). Tests:
  `tests/capture_git_diff_tests.l` (real `git diff` fixtures) +
  `tests/checkpoint_bridge_tests.l` (real diff → file_change step + re-anchored
  checkpoint). `beforeSha256`/`afterSha256` stay `None` (git blob ids are SHA-1,
  not SHA-256; attribution needs only ranges). **The capture→checkpoint pipeline
  is now LIVE-verified on a genuinely fresh real session**
  (`tests/live_capture_e2e_tests.l`): a live `claude -p --output-format
  stream-json` run really edited `app.py` (Edit tool), and its verbatim NDJSON +
  real `git diff HEAD` (`tests/fixtures/stream-json/live-edit-turn.ndjson` /
  `live-edit.diff`) run through the exact runner calls (`parseStreamJson` →
  `verifyChain` → `emitFromCaptureWithDiff`) to emit a checkpoint whose
  `file_change` hunk matches the diff (+1,6). **The RUNTIME wiring has now landed
  too** (opt-in): `src/docker_manager.l`'s `emitRunnerCheckpoint` is called from both
  successful-run seams (`streamSessionMessage` + `runSessionMessageBlocking`, both
  sync — no `await`, so #6249-safe), **gated behind the
  `CLOUDAGENTS_CAPTURE_CHECKPOINTS` env flag (OFF by default, #1020)** since the
  inspect-container round trip taxes every run's hot path for a currently-logged-only
  result. When enabled it captures the workspace `git diff HEAD` via the existing
  inspect container (`runInspectContainer(…, "diff", …)` → section 2), builds the
  `InvocationContext` (agent-convention principal `"agent:" + harness`, #1019;
  `Repository.nowRfc3339Utc()` invariant-culture `startedAt`), and calls the pure
  `CheckpointBridge.emitFromRunnerCapture(rawNdjson, diff, ctx)` on the run's raw
  NDJSON. Best-effort (a diff/mapping failure is logged, never fails the run); logs
  a structured summary.
  The pure `emitFromRunnerCapture` is unit-tested on the real fixtures; the
  docker_manager glue needs a live Docker host to observe (@test_module can't reach
  `CloudAgents.Docker`).
- **Runtime graph handoff + terminal checkpoint (M1.2) — landed**
  (`docs/capture-runtime-handoff.md`). Both of the prior bullet's deferrals are
  now closed. (1) The inspect `diff` mode's entrypoint emits a 4th section, the
  workspace tree hash (`git rev-parse --verify HEAD^{tree}`, or — when there is no
  `HEAD` yet — a throwaway-index `git write-tree` fallback so a fresh repo before
  its first commit still anchors a checkpoint, dogfood F3; `--verify` is
  load-bearing, a bare `rev-parse HEAD^{tree}` prints the literal `HEAD^{tree}` on
  a no-HEAD repo), which `emitRunnerCheckpoint` threads as
  `runnerContext(…, Some(tree))` — so a run now emits a **terminal checkpoint**
  (`mapping.checkpointId = Some(…)`); only a workspace where even the fallback
  fails degrades to steps-only (`None`) without error. (2) After a successful emit the
  runner **POSTs the emitted `ProvenanceObject`s** to the platform graph
  service's `POST /api/ingest` (objects form, `{"objects":[…]}` via the new pure
  `CheckpointBridge.objectsToIngestJson`), gated behind the existing
  `CLOUDAGENTS_CAPTURE_CHECKPOINTS` flag plus `CLOUDAGENTS_GRAPH_INGEST_URL`
  (empty ⇒ log-only, today's behavior exactly) and `CLOUDAGENTS_GRAPH_INGEST_TOKEN`
  (empty ⇒ skip, never POST unauthenticated). The POST reuses
  `GitHubApi.httpPostJsonWithBearerTimeout` (bearer, bounded 15s timeout,
  2xx-only, now no-redirect via `setAllowAutoRedirect(false)` — bearer-leak
  defense); best-effort throughout (every hop logged and swallowed, never fails
  the run) and synchronous (no new `await`, #6249-safe). `objectsToIngestJson` is
  unit-tested offline on the real live-edit fixtures (byte-identical to the
  platform's `Model.encodeObject` + `Canon.encodeCanonical`); the docker glue +
  the live POST need a live Docker host + a running graph service to observe (the
  documented manual step). Still deferred: a durable outbox/retry (today's POST is
  at-most-once fire-and-forget), credential issuance for the bearer, and the NuGet
  migration of the vendored contract.
- **Audit-row enrichment — derivation built, checkpoint attachment deferred.**
  `CloudAgents.PermissionEnrichment` (`src/capture/permission_enrichment.l`,
  `docs/capture-permission-enrichment.md`) folds the existing
  `permission_requests`/`secret_requests` rows into a per-tool `permission` map
  (`derivePermissions` + `permissionForTool` + `permissionsForSession`,
  conservative `Denied > Granted > Auto` fold), replacing the single
  context-level mode. It ships the derivation + accessor + tests
  (`tests/permission_enrichment_tests.l`, offline + live-SQLite). Attaching the
  map to the emitted checkpoint steps is the remaining piece: the step-permission
  assignment lives in the **vendored** `Adapt.mapStreamJson`
  (`vendor/testamur-checkpoint-format/`, the drift-guard / content-address
  contract), which supports only one session-level permission — teaching it a
  per-tool map is a change to the shared checkpoint-format contract and belongs
  upstream in testamur, not as a local fork (see the spec §"Attachment point").
- **NuGet migration**: replace the vendored copy with a published
  `Testamur.CheckpointFormat` NuGet package.
