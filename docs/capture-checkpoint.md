# Spec: `CloudAgents.CheckpointBridge` — capture → Testamur checkpoint format

Status: **Implemented.** WP6 of the provenance-capture work (Testamur §4.1 /
ADR-0004; `docs/CAPABILITY_AUDIT.md` WP4). Written alongside the implementation,
following the capture core (`docs/capture-stream-json.md`).

## 1. Purpose and scope

`CloudAgents.Capture` turns a captured `claude -p --output-format stream-json`
run into hash-chained `CaptureEvent`s. This package is the next link: it
**emits the Testamur checkpoint format** from those events — a `Session`, its
`Step`s, and a terminal `Checkpoint`, content-addressed exactly as the platform
computes them — so a real cloud-agents session can be ingested by the Testamur
unified graph and answered by its four canonical queries (the §9.4 vertical
slice: *session → checkpoints → attribution → graph → CI annotation*).

**In scope:** a pure, offline bridge — verify the capture chain, reconstruct the
transcript from the event payloads, and map it to checkpoint-format objects —
plus a small helper to build the runner's invocation context, and typed errors.

**Out of scope / deferred (§7):** persisting the emitted objects or the events
(the `session_events` store); serving them over HTTP; wiring the Docker runner to
`--output-format stream-json`; handing the objects to the platform's `GraphIngest`;
folding the `permission_requests`/`secret_requests` audit rows into per-tool
permission; and replacing the vendored contract copy with a NuGet dependency.

## 2. The checkpoint-format contract (vendored, for now)

The checkpoint format — the data model, canonical JSON, content addressing,
signing hooks, and the reviewed capture→checkpoint mapper — is
`Testamur.CheckpointFormat`, which lives in the sibling `nichobbs/testamur`
repository. cloud-agents has no testamur dependency, and Lyric consumes
third-party code only through NuGet, so until that contract is published as a
Lyric ecosystem package it is **vendored verbatim** under
`vendor/testamur-checkpoint-format/` (see its `VENDORED.md` for provenance and
the migration plan). This was a deliberate *copy-now-migrate-later* decision.

The package names are kept identical to upstream (`Testamur.CheckpointFormat.*`),
which is what makes the eventual NuGet swap a manifest-only change **and** what
guarantees the content addresses emitted here are byte-identical to testamur's.

## 3. Not a second mapper

The event → step mapping is the platform's, not this package's. The bridge
delegates to `Testamur.CheckpointFormat.Adapt.mapStreamJson` — the reviewed
`cloud-agents-runner` capture adapter (fidelity: `events`). That mapper owns all
the semantics that must not diverge:

- honest origins (`human` for the synthesized prompt, `agent` for responses/
  tool-uses, `tool` for adapter notes — never fabricated attribution);
- `tool_use` + its later `tool_result` merge into one `tool_use` step;
- every unmappable record (unknown event, unparseable line, unmatched
  `tool_result`, a `tool_use` with no result) becomes a **note** step — nothing
  is silently dropped, and `mapped + notes == total` always holds;
- the timestamp policy (data only, never the wall clock; truncated to seconds;
  inherit last-seen, floor at `startedAt`);
- content addressing (`sess-`/`step-`/`ckpt-` ids over canonical JSON).

Keeping the mapping in one vendored place is what the cross-repo drift guard
(§6) pins.

## 4. What the bridge adds

1. **Verify before trust.** `CloudAgents.Capture.verifyChain` runs first; a
   discontinuous or mutated capture is rejected as `ChainInvalid`, never mapped
   into provenance.
2. **Reconstruct the transcript.** `CaptureEvent.payload` is the raw NDJSON line
   verbatim; the ordered payloads *are* the stream-json transcript the mapper
   expects. Blank lines were already dropped at capture, so the reconstructed
   line set matches what the platform's own `splitLines` would produce — the
   basis for identical content addresses. Malformed-captured lines pass through
   too (the mapper notes them).

## 5. API

```
emitFromCapture(events: slice[CaptureEvent], genesisPrevHash: String,
                context: InvocationContext) -> Result[StreamJsonMapping, BridgeError]
emitFromTranscript(ndjson: String, context: InvocationContext)
                -> Result[StreamJsonMapping, BridgeError]   // parse + emit, one call
emitFromCaptureWithFileChanges(events, genesisPrevHash, context,
                fileChanges: List[FileDelta]) -> Result[StreamJsonMapping, BridgeError]
emitFromCaptureWithDiff(events, genesisPrevHash, context,
                gitDiff: String) -> Result[StreamJsonMapping, BridgeError]
runnerContext(principalId, principalDisplay, workspace, startedAt, promptText,
              model, permission, treeHash: Option[String]) -> InvocationContext
permissionOf(mode: String) -> Permission                    // "granted"|"denied"|else→auto
```

- `emitFromCapture` is the core: verify → reconstruct → `mapStreamJson`. The
  returned `StreamJsonMapping` carries the objects (dependency order), the
  per-event kind labels, the `mapped`/`note` accounting, the session id, and the
  checkpoint id (present iff `context.tree` is set).
- `emitFromCaptureWithFileChanges` also threads captured workspace `FileDelta`s
  through the vendored `Adapt.mapStreamJsonWithFileChanges` (testamur ADR-0016):
  a non-empty list adds one agent-origin `file_change` step as the checkpoint
  frontier tip, so **Q4 attributes a PR hunk to this session**; an empty list is
  byte-identical to `emitFromCapture` (content addresses unchanged — the
  cross-repo drift-guard still pins the exact ids). `emitFromCapture` now
  delegates to it with an empty list.
- `emitFromCaptureWithDiff` is the runner seam: it parses the raw workspace
  `git diff` (the runner's inspect-diff `git diff HEAD` output) into `FileDelta`s
  via `CloudAgents.Capture.GitDiff.parseUnifiedDiff`, then calls the above. A
  malformed/empty diff parses to no deltas ⇒ byte-identical to `emitFromCapture`
  (fails safe).
- `emitFromTranscript` composes `parseStreamJson` (from seq 0, genesis `""`) with
  `emitFromCapture` for callers that don't need to keep the `CaptureEvent`s.
- `runnerContext` builds the `InvocationContext` from primitives so callers need
  not import the vendored `Model`/`Adapt` records; the prompt is CLI input (not a
  stream event in `-p` mode), so it is synthesized as the session's root step.
- `BridgeError`: `ChainInvalid(detail)` (verify failed) | `MapFailed(detail)` (a
  vendored `AdaptError`, e.g. ill-formed UTF-16 rejected before hashing). Never
  panics; a capture with no mappable events is not an error.

## 6. Test strategy (offline only)

Mirrors the capture core: no Docker/DB/network, no wall-clock reads, literal
NDJSON, fixed literal timestamps (`tests/checkpoint_bridge_tests.l`).

- **Cross-repo drift guard (headline).** A fixed captured transcript + context is
  mapped through the bridge and asserted to produce the **exact** `sess-`/`ckpt-`
  content addresses that testamur computes for the identical input (the expected
  ids were computed by running `Adapt.mapStreamJson` in the testamur repo). If
  the vendored copy ever drifts from upstream behavior, this fails.
- **Event accounting**: `mapped + notes == total`; the exact per-event kind
  sequence; the object count (session + steps + checkpoint).
- **No tree** ⇒ no terminal checkpoint (mapping stops at steps).
- **Tamper rejection**: a mutated payload (stored hash kept) and a wrong genesis
  `prevHash` both yield `ChainInvalid`, never a mapped result.
- **Gaps as notes**: a malformed captured line survives as a note step; nothing
  is dropped.

## 7. Acceptance criteria

1. A captured transcript emits a `Session` + `Step`s + terminal `Checkpoint`
   whose content addresses match testamur's for the same input (drift guard).
2. A tampered or discontinuous capture is rejected as a typed `BridgeError`
   before mapping; the bridge never panics.
3. Every captured line is accounted for (mapped or noted), never silently
   dropped; `mapped + notes == total`.
4. Offline suite passes with no DB/Docker/network; no wall-clock reads.
5. `file_change` capture (ADR-0016): `emitFromCaptureWithDiff` on a real workspace
   `git diff` emits one agent-origin `file_change` step as the checkpoint frontier
   tip (so **Q4 attributes a PR hunk to the session**), while an empty/malformed
   diff is byte-identical to `emitFromCapture` (criterion 1's drift-guard ids
   unchanged).

## 8. Deferred (sequenced follow-ups)

- **Persistence**: a `session_events` table (+ migration + `Repository` accessor)
  and `GET /api/sessions/{id}/events?after=seq` (audit WP4 acceptance), so the
  emitted chain is stored and served.
- **Runner wiring — landed** (#972): `docker/entrypoint.sh` emits
  `--output-format stream-json` and the poll loop parses per-event.
- **`file_change` capture — bridge wired** (#127 + #982, ADR-0016):
  `emitFromCaptureWithDiff` turns a captured workspace `git diff` into an
  agent-origin `file_change` step so **Q4 answers on a captured session** (proven
  on live PG in testamur #127).
- **`file_change` capture — LIVE-verified on a real editing session.** The
  capture→checkpoint pipeline is now exercised end-to-end on a GENUINELY FRESH
  session: a live `claude -p --output-format stream-json --verbose` run was
  pointed at a real git workspace and told to add a function; it used the Edit
  tool and actually changed the file. The verbatim NDJSON transcript
  (`tests/fixtures/stream-json/live-edit-turn.ndjson`) and the real `git diff HEAD`
  (`tests/fixtures/stream-json/live-edit.diff`) run through the exact runner calls
  — `parseStreamJson` → `verifyChain` → `emitFromCaptureWithDiff` — and produce a
  content-addressed checkpoint whose `file_change` hunk matches the real diff
  (`app.py`, +1,6; blob sha256s `None`), with the chain verifying and no event
  dropped (`tests/live_capture_e2e_tests.l`). This is the manual end-to-end step
  the notes above flagged as pending — done on real data, not fixtures-by-hand.
- **`file_change` capture — RUNTIME wiring landed (opt-in).** The runner emits a
  checkpoint at end-of-run. `src/docker_manager.l`'s `emitRunnerCheckpoint` is
  called from BOTH successful-run seams (`streamSessionMessage` and
  `runSessionMessageBlocking`, both sync — no new `await`, so not exposed to
  lyric-lang#6249). It is **gated behind the `CLOUDAGENTS_CAPTURE_CHECKPOINTS` env
  flag, OFF by default** (#1020): the emission adds a synchronous second
  inspect-container round trip to the hot path of every successful run, so until
  the graph handoff makes the objects useful (today they are only logged), it must
  not tax every run — operators running provenance capture opt in with the flag.
  When enabled it captures the workspace `git diff HEAD` via the existing inspect
  container (`runInspectContainer(…, "diff", …)` → `parseInspectLog` → section 2),
  builds the runner's `InvocationContext` (agent-convention principal
  `"agent:" + harness` with the harness as display, #1019; `nowRfc3339Utc()`
  invariant-culture timestamp for `startedAt`), and calls the pure
  `CheckpointBridge.emitFromRunnerCapture(rawNdjson, diff, context)` (=
  `parseStreamJson` + `emitFromCaptureWithDiff`) on the run's raw NDJSON
  (`cell.output`). It is **best-effort** — any inspect/diff/mapping failure is
  logged and swallowed, never failing the run — and logs a structured summary
  (session id, object count, mapped/note counts, checkpoint id). The pure
  `emitFromRunnerCapture` is unit-tested on the real fixtures
  (`tests/live_capture_e2e_tests.l`); the docker_manager glue itself needs a live
  Docker host to observe (the `@test_module` async-import limitation), which is the
  one remaining manual check. Two deferred follow-ups keep this a first honest cut:
  `treeHash` is `None` (the workspace git tree id isn't captured yet, so the mapping
  is steps + the `file_change` step with **no terminal checkpoint** at runtime — a
  real tree hash means extending the inspect `diff` mode to also print
  `git rev-parse HEAD^{tree}`), and the emitted objects are logged rather than
  handed to the graph (the cross-repo handoff below). Caveat: `git diff HEAD`
  shows only uncommitted working-tree changes — a run whose harness committed its
  edits produces an empty diff and a steps-only mapping.
- **Graph handoff**: pass the emitted objects to the platform's `GraphIngest`
  (cross-repo; today the objects are the deliverable).
- **Audit-row enrichment**: fold `permission_requests`/`secret_requests` into
  per-tool `permission` rather than the single context-level mode.
- **NuGet migration**: replace the vendored copy with a published
  `Testamur.CheckpointFormat` NuGet package (see `VENDORED.md`).
