# `CloudAgents.Capture.GitDiff` — unified-diff → `FileDelta` parser

Status: **Implemented** (offline core). Part of the Q4 file-change-capture arc
(Testamur ADR-0008 §capture-completeness).

## Why

Testamur's **Q4** ("which PR hunk did which agent step produce?") attributes a
hunk through the graph's `line_attribution`, which the platform derives from a
checkpoint's **`file_change`** steps — their new-side hunk ranges plus the step's
origin. The stream-json transcript the runner captures carries *no* diffs, so a
stream-json-only session ingests its session/steps/checkpoint but yields **no**
line attribution, and Q4 returns `None` (a tested fact, ADR-0008). Answering Q4 on
a real runner session therefore requires the runner to also capture the
workspace's `git diff` as `file_change` steps.

This module is the **pure, offline first piece** of that arc: it turns `git diff`
unified-format text into `List[FileDelta]` (the checkpoint-format
`Testamur.CheckpointFormat.Model` type a `file_change` step carries). It does no
git, Docker, DB, or HTTP work and is fully unit-tested on real captured `git diff`
output (`tests/capture_git_diff_tests.l`).

## API

```
pub func parseUnifiedDiff(diff: String): List[FileDelta]
pub func parseHunkNewRange(line: String): Option[HunkRange]
```

- `parseUnifiedDiff` — one `FileDelta` per changed file, in file order, each with
  its **new-side** hunk ranges (`@@ … +newStart[,newCount] @@` → `HunkRange{start,
  lines}`; an omitted count means 1, git's elision of `,1`). Total: a malformed or
  empty diff yields an empty list, never a throw.
- `parseHunkNewRange` — the single-hunk-header helper, exposed for direct testing.

**Path**: taken from `+++ b/<path>` (the post-change path), or from `--- a/<path>`
for a deletion (`+++ /dev/null`), or from the unambiguous `rename to <path>` /
`copy to <path>` line for a rename-/copy-only change with no `+++`/`---`. The
`diff --git a/… b/…` header is only a last-resort fallback (its `a/…b/…` split is
ambiguous for paths containing ` b/`, so the target-line forms are preferred). The
`a/`/`b/` prefix is stripped. **Residual (documented, low-impact):** a **binary**
change carries no target line and no `+++`/`---`, so its path comes only from the
header split — ambiguous for a binary path containing ` b/`. Binary files carry no
hunks, so they contribute nothing to Q4 line attribution regardless; the runner
can also capture with `-c core.quotePath=false` and unabbreviated paths.

**File kinds**: modify, add (`--- /dev/null`), delete (`+++ /dev/null`, new-side
range `+c,0` → a zero-length hunk at `c`), rename (path from the header, no hunks),
binary (no hunks).

## Deliberate non-goals (this module)

- `beforeSha256`/`afterSha256` are left `None`. The `index <old>..<new>` line
  carries git **blob** ids that are SHA-1 in a normal repo, not SHA-256, so
  populating the sha256-named fields with them would misrepresent the hash — and
  Q4 attribution needs only the hunk ranges + step origin, not the blob hashes.
  Real blob-hash capture (a sha256-object repo, or a separate channel) is a later
  refinement.
- Quoted paths (git's `"path with spaces"` C-style quoting under
  `core.quotePath`) are taken verbatim including the quotes; the runner should
  capture with `-c core.quotePath=false` for plain UTF-8 paths. Unquoting is a
  later refinement if needed.

## The rest of the Q4 arc (sequenced follow-ups)

1. **Contract change (testamur) — LANDED** (#127, ADR-0016).
   `CheckpointFormat.Adapt.mapStreamJsonWithFileChanges` accepts captured file
   deltas and emits an agent-origin `file_change` step as the checkpoint frontier
   tip; Q4 answers on a captured session, proven on live PG. Re-vendored into
   cloud-agents (`vendor/testamur-checkpoint-format/`).
2. **Bridge wiring (cloud-agents) — LANDED** (#982).
   `CheckpointBridge.emitFromCaptureWithDiff` parses a captured workspace `git
   diff` here and threads the deltas through the vendored mapper, so a captured
   session + a real diff emits a `file_change`-bearing checkpoint. The runner's
   inspect-diff path already produces the `git diff HEAD` this consumes; empty
   deltas keep the drift-guard ids exact.
3. **Runner live flow (cloud-agents) — remaining.** Wire the runner's runtime
   path (capture events → `emitFromCaptureWithDiff` → the graph handoff) and
   live-verify end-to-end in a container. This is the same cross-repo
   `CaptureFetch` graph handoff the whole capture arc defers; the emitted objects
   are the deliverable until then.

The parser itself remains a pure offline core — the same offline-core-first
pattern the capture and display-render cores followed before the runner flip.
