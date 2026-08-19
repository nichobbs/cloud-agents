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

## 8. Deferred (sequenced follow-ups)

- **Persistence**: a `session_events` table (+ migration + `Repository` accessor)
  and `GET /api/sessions/{id}/events?after=seq` (audit WP4 acceptance), so the
  emitted chain is stored and served.
- **Runner wiring**: flip `docker/entrypoint.sh` to `--output-format stream-json`
  and parse per-event in the poll loop (`src/docker_manager.l`) — needs a Docker
  host + the real `claude` harness to verify without regressing the PWA stream.
- **Graph handoff**: pass the emitted objects to the platform's `GraphIngest`
  (cross-repo; today the objects are the deliverable).
- **Audit-row enrichment**: fold `permission_requests`/`secret_requests` into
  per-tool `permission` rather than the single context-level mode.
- **NuGet migration**: replace the vendored copy with a published
  `Testamur.CheckpointFormat` NuGet package (see `VENDORED.md`).
