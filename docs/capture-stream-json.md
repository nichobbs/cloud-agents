# Spec: `CloudAgents.Capture` — stream-json event capture core

Status: **Draft for review**. The offline, verifiable core of the provenance
**capture adapter** (`docs/CAPABILITY_AUDIT.md` WP4; Testamur architecture
§4.1 / ADR-0004 "capture at the runner … switch the runner to
`--output-format stream-json` … normalise … into the checkpoint format").

## 1. Purpose and scope

Today the runner throws structure away: a session's agent turn is captured as
one raw ANSI blob (`src/handlers/sessions.l:565`), built by diffing `docker
logs` (`src/docker_manager.l:644`). WP4 replaces that with **structured
per-event capture** from `claude -p --output-format stream-json` (NDJSON, one
JSON object per line). This package is the **pure parsing + integrity core** of
that adapter: turn a stream-json byte stream into typed, sequence-numbered,
**hash-chained** `CaptureEvent` records, incrementally (the runner feeds chunks
as they arrive) and losslessly (a malformed line is captured, never dropped).
It is the structured input the checkpoint-format emitter (WP6) later normalises
into `Session → Step → Checkpoint`.

**In scope (this work package):** the `CaptureEvent` model, `parseStreamJson`
(NDJSON → events with monotonic `seq` + a tamper-evident hash chain, resumable
across chunks), and `verifyChain`. Pure Lyric, no Docker, no DB, no HTTP —
fully offline-testable.

**Out of scope / deferred (§7):**
- **Runner wiring** — flipping `docker/entrypoint.sh:486` to
  `--output-format stream-json [--include-partial-messages]`, parsing per-event
  in the poll loop (`src/docker_manager.l:644`) instead of byte-diffing, and
  reconstructing the human text stream for the PWA from the events. This
  requires a Docker host running the real `claude` harness to verify and is a
  separate follow-up (it must not regress the existing UI stream).
- **Persistence** — a `session_events` table (+ migration + `Repository`
  accessor) and the `GET /api/sessions/{id}/events?after=seq` endpoint (WP4's
  acceptance surface). The event model here is what those rows store; the store
  is a follow-up.
- **Checkpoint-format emitter (WP6)** — mapping `session_events` (+ the existing
  `permission_requests` / `secret_requests` audit rows) into the Testamur
  checkpoint format. That is **gated on an open decision**: cloud-agents has no
  dependency on testamur and Lyric consumes NuGet only, so reaching the
  checkpoint-format contract needs either a published NuGet package or a native
  re-implementation of the schema. Recorded, not resolved here.

## 2. The stream-json shape (input)

`claude -p --output-format stream-json` emits NDJSON — one JSON object per line,
each with a `"type"` discriminator. The observed top-level types (Claude Code):
`system` (e.g. `subtype:"init"`), `assistant` (a model message),
`user` (tool results fed back), `result` (the terminal turn summary), and, with
`--include-partial-messages`, `stream_event` (incremental deltas). This package
treats `"type"` as an **open** set: it records the discriminator verbatim and
keeps the whole line as the payload; it does not enumerate or validate the inner
message shape (that is the emitter's concern, WP6). Capture is about fidelity,
not interpretation.

## 3. The event model

```
CaptureEvent {
  seq:       Long    // 0-based, monotonic within a session capture
  eventType: String  // the line's "type" (verbatim), or "malformed" (§4)
  payload:   String  // the raw NDJSON line, exactly as captured
  prevHash:  String  // hash of the previous event ("" for the genesis event)
  hash:      String  // this event's chain hash (§4)
}
```

The `payload` is the **verbatim** line (not re-serialized), so capture is a
faithful record and the emitter/analysts see exactly what the harness produced.

## 4. Parsing + hash chain

```
parseStreamJson(ndjson: String, startSeq: Long, prevHash: String) -> CaptureBatch
CaptureBatch { events: slice[CaptureEvent], nextSeq: Long, lastHash: String }
```

- Split `ndjson` on `\n` using the proven character-scan idiom
  (`CloudAgents.Text.indexOfFrom` + `substring`), **not** `String.split()` —
  which this repo treats as an unproven runtime landmine (`handlers/search.l`).
  **Strip a single trailing `\r`** so CRLF framing parses identically to LF;
  **skip blank lines** (NDJSON framing), keep every other line as one event.
  (`events` is a `slice[CaptureEvent]`, the repo's collection idiom — built
  internally with `newList()`/`.add`, then `.toArray()`.)
- `eventType` = the line's `"type"` string, read via the `Std.Json` DOM
  (`tryParseJson` → `rootElement` → `tryGetProperty("type")`, guarded on
  `valueKind` before `getString` so a non-string `type` can't throw). A line
  that is **not valid JSON**, or a JSON value with no string `"type"`, is
  captured with `eventType = "malformed"` and the raw payload — **never
  dropped** (integrity over interpretation; a provenance/security capture must
  not silently lose bytes).
- **Hash chain** (tamper evidence, mirroring the platform's checkpoint chain):
  each field is **length-prefixed** (`<len>:<value>`) before joining —
  `hash = base64(sha256("<len>:prevHash;seq;<len>:eventType;<len>:payload"))` —
  so the preimage is unambiguous: no crafted `eventType`/`payload` (even one
  with a delimiter or decoded newline) can collide with a different field tuple.
  The whole record is covered, so a tamper that mutates only `seq` or
  `eventType` (not just `payload`) also breaks the chain. Hashing reuses the
  proven `CloudAgents.Crypto.sha256Base64`. Each event's `prevHash` is the prior
  event's `hash`; the genesis event's `prevHash` is `""`. Any
  edit/insert/reorder/drop of a captured line breaks every subsequent `hash`.
- **Resumable**: `startSeq` / `prevHash` let the runner feed the stream in
  chunks (as `docker logs` deltas arrive) and continue one chain across calls.
  `nextSeq` / `lastHash` in the result are the inputs for the next chunk.
  Splitting the same byte stream into different chunk boundaries yields the same
  events and hashes (blank-line framing makes chunking irrelevant, provided
  chunks split on line boundaries — the runner buffers a partial trailing line;
  documented as the caller's contract).
- `parseStreamJson` is **total** — it returns a batch, never an error; a bad
  line is data (`"malformed"`), not a failure.

```
verifyChain(events: slice[CaptureEvent], genesisPrevHash: String) -> Bool
```

Recomputes the chain from `genesisPrevHash` and returns `false` on the first
mismatch (or a `prevHash` discontinuity) — the tamper check a consumer runs
before trusting a captured stream.

## 5. Package layout

```
CloudAgents.Capture   (src/capture/stream_json.l)   CaptureEvent / CaptureBatch,
                                                     parseStreamJson, verifyChain
```

Dependencies are all in-repo/stdlib: `Std.Core` / `Std.Collections` /
`Std.Json` (DOM) + `CloudAgents.Crypto` (for `sha256Base64` — reusing the
proven SHA-256 binding rather than introducing new externs). Declare the
package **after** `CloudAgents.Crypto` in `lyric.toml` `[project.packages]`
(dependency order), and add a suite to `[project.tests]`.

## 6. Test strategy (offline only)

`@test_module` suites under `lyric test`, no Docker/DB/network, no wall-clock
reads — fixtures are literal NDJSON strings. The shipped suite
(`tests/capture_tests.l`) has **10 tests**:

1. **A representative turn** — `system`/`assistant`/`user`/`result` lines parse
   to four events with `seq` 0..3, the right `eventType`s, verbatim payloads.
2. **Hash chain** — `prevHash` links, `hash` is deterministic (same input →
   same hashes), 44-char base64, the genesis `prevHash` is `""`.
3. **Malformed line** — a non-JSON line and a JSON line with no `"type"` are
   captured as `"malformed"` with the raw payload; the chain continues.
4. **Blank lines** — leading/trailing/interior blank lines are skipped.
5. **Incremental** — parsing `chunkA` then `chunkB` (feeding `nextSeq`/
   `lastHash` forward) yields the same events + hashes as parsing `chunkA+chunkB`
   at once (compared positionally on the slices).
6. **Empty input** — no events, `nextSeq == startSeq`, `lastHash == prevHash`.
7. **verifyChain** — rejects a mutated payload, a reordered pair, a dropped
   event, and a wrong genesis `prevHash`.
8. **Whole-record hash** — a mutation of only the stored `eventType` (payload
   and hash left intact) is still detected.
9. **CRLF** — CRLF-framed input parses identically to LF (same events, same
   hashes).
10. **Non-string `type`** — `{"type":123}` / `{"type":true}` are captured as
    `"malformed"` (the `valueKind`-before-`getString` guard).

## 7. Acceptance criteria

1. A fixture stream-json turn parses to correctly-typed, `seq`-ordered,
   verbatim-payload events (test 1).
2. The hash chain is deterministic and links every event; `verifyChain` detects
   payload mutation, reordering, and drops (tests 2, 7).
3. Malformed and blank lines are handled losslessly — malformed captured as
   `"malformed"`, blank skipped — never a crash or a dropped byte (tests 3, 4).
4. Chunked parsing equals whole-stream parsing on line-aligned splits (test 5).
5. Offline suites pass with no Docker/DB/network and no wall-clock reads.

## 8. Deferred (restated)

Runner entrypoint flag + poll-loop per-event parse + PWA text reconstruction;
the `session_events` table/accessor + `GET …/events?after=seq` endpoint; the
WP6 checkpoint-format emitter and its testamur-contract dependency decision.
Each is its own follow-up; this package is the verifiable core they build on.
