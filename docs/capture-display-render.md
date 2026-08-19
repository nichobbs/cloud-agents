# Spec: `CloudAgents.Capture.Render` — display-text reconstruction from stream-json

Status: **Draft for implementation** (audit WP4 follow-up; the enabling piece for
the runner entrypoint flip). Written before implementation, per the working
practice.

## 1. Purpose and scope

The runner today invokes `claude -p "$PROMPT"` in **plain-text** `--print` mode
(`docker/entrypoint.sh:486`), and the poll loop byte-diffs the container log
straight to the PWA as the visible transcript
(`docker_manager.l:644` → `Streaming.outputDelta`/`toSseChunk`). Provenance
capture (`CloudAgents.Capture`, ADR-0004) needs the run in
`--output-format stream-json` mode instead — but that turns the container log
into NDJSON, which byte-diffed to the PWA would show raw JSON, a hard UI
regression.

This package is the **missing pure piece** that makes the flip safe: given the
already-parsed `CaptureEvent`s, reconstruct the human-readable assistant text the
PWA used to receive from plain `--print` output. It does **no** Docker/DB/HTTP
work and does **not** change the entrypoint or the poll loop — those are the
follow-up (`§6`). It is the reconstruction contract, grounded on **real** harness
output, that the flip depends on.

**In scope:** `displayTextOf(event)` (one event's visible-text contribution),
`renderDisplayText(events)` (the transcript text for a batch), and
`finalResultText(events)` (the terminal `result` payload's `result` string, for
persisting the agent message). Real-harness fixtures + offline tests.

**Out of scope / deferred (`§6`):** the entrypoint flag flip; the poll-loop
per-event parse + `appendSessionEvents` persistence; converting the
`getRunOutput`/`getRunOutputFrom` read-back paths through this renderer;
file-change (`file_change` step) capture for Q4.

## 2. The real stream-json schema (captured, not assumed)

Grounded on two **real** `claude -p --output-format stream-json --verbose` runs
against a live harness (`tests/fixtures/stream-json/`, sanitized only for
session-identifying ids/paths — structure and payloads verbatim):

- `simple-turn.ndjson` — 8 events, a one-line reply (`result` = `"pong"`).
- `tool-use-turn.ndjson` — 13 events, a Read-tool turn (`result` = `"3"`),
  exercising `assistant` events with `thinking`, `tool_use`, and `text` blocks,
  plus a `user` event carrying a `tool_result` block.

Event `type`s observed (an **open set** — the capture core records each verbatim
and this renderer must ignore any it does not display): `active_goal`,
`autocompact_state`, `rate_limit_event`, `system` (subtypes `commands_changed`,
`init`, `task_summary`, `post_turn_summary`), `assistant`, `user`, `result`.

Visible assistant text lives at `message.content[]` elements with
`{"type":"text","text":"…"}`. `thinking` and `tool_use` blocks are **not** part
of the plain-`--print` transcript and are excluded here (matching current UI
behavior; surfacing them is a later UI enhancement, not this contract). The
terminal event is `{"type":"result","subtype":"success","result":"…"}`.

## 3. Behavior

- `displayTextOf(event)`: `""` unless `event.eventType == "assistant"`. For an
  assistant event, parse `payload`, walk `message.content[]`, concatenate the
  `text` of every `{"type":"text"}` block in array order (no separator within an
  event). Total: a non-JSON payload, a missing/`non-array` `content`, or a
  block whose `text` is absent/non-string contributes `""` — never throws
  (`getString` on a lone-surrogate string is caught, as in the vendored adapter).
- `renderDisplayText(events)`: join the non-empty `displayTextOf` contributions
  in `seq` order with `"\n"`. Empty when no assistant text is present.
- `finalResultText(events)`: `Some(result)` for the **last** `result`-typed
  event whose `result` is a string; `None` if there is none.

## 4. Test strategy (offline, no Docker/DB/network)

- **Fixture, simple:** parse `simple-turn.ndjson` via `Capture.parseStreamJson`;
  assert 8 events, `verifyChain` true, `renderDisplayText == "pong"`,
  `finalResultText == Some("pong")`.
- **Fixture, tool-use:** parse `tool-use-turn.ndjson`; assert `verifyChain` true,
  `renderDisplayText == "3"` (the single visible `text` block — `thinking`/
  `tool_use`/`tool_result` excluded), `finalResultText == Some("3")`.
- **Unit:** a synthetic assistant event with two `text` blocks concatenates them;
  a `thinking`-only assistant event renders `""`; a control event (`system/init`)
  renders `""`; a malformed payload renders `""` (no throw); `finalResultText`
  returns `None` when no `result` event is present.

## 5. Acceptance criteria

1. `renderDisplayText` reproduces the visible assistant transcript of a **real**
   captured stream-json turn (both fixtures), excluding thinking/tool blocks.
2. `finalResultText` returns the terminal result string, `None` when absent.
3. Total on adversarial input (non-JSON, non-string `text`, lone surrogate) — no
   throw, `""`/`None`.
4. Offline suite passes with no Docker/DB/network and no wall-clock reads.

## 6. The flip this unblocks — LANDED

Landed as the runner entrypoint flip (this file's original §6 deferred
follow-up). The reconstruction contract above stays pure/offline; the wiring
below is the runtime-executed side that consumes it. The `renderLogDelta` /
`renderFullLog` helpers added to `src/capture/render.l` are the seam: each takes
a full NDJSON log + a byte offset + carried chain state (`nextSeq`/`lastHash`),
parses only the COMPLETE lines past the offset (a partial trailing line is left
for the next tick), and returns `{displayText, events, consumed, nextSeq,
lastHash}`. They are unit-tested (`tests/capture_render_tests.l`).

1. `docker/entrypoint.sh` — `--output-format stream-json --verbose` is added to
   every `claude -p` invocation site via a shared `STREAM_JSON_ARGS` array (5
   spots: first-run, `--session-id`, `--resume`). `--verbose` is required
   alongside `stream-json` in `-p` mode.
2. `docker_manager.l` poll loop (`streamSessionMessage`) — replaced the
   `outputDelta` byte-diff with `renderLogDelta`: parse the new complete NDJSON
   lines (carrying `nextSeq`/`lastHash` forward), persist the events
   (`Repository.appendSessionEvents`, idempotent, best-effort), and stream
   `rd.displayText` to the PWA via the existing `toSseChunk` framing. The
   offset advances by `rd.consumed` (complete lines only) on a successful write.
   The final flush persists the tail events and RETURNS `renderFullLog(finalLogs)`
   — the rendered transcript, never the raw NDJSON — because the caller persists
   the return as the agent message and parses it for a plan.
3. `getRunOutput` / `getRunOutputFrom` (`handlers/sessions.l`) — the reconnect/
   replay read-back paths route the container log through the renderer:
   `getRunOutput` returns `renderFullLog(logs)`; `getRunOutputFrom` uses the new
   `runOutputRenderedDeltaJson`, which renders the delta past the client offset
   and reports the advanced line-boundary offset as `length`. Resync (offset past
   total) is preserved. `runOutputDeltaJson` (plain byte-delta) is kept unchanged
   for the older text `/output` route and its existing unit tests.

**Still deferred — not part of this flip:** `file_change` step capture for Q4.
The stream-json mapper does not emit `file_change` steps (testamur ADR-0008), so
Q4 stays `None` on a stream-json-only session until the entrypoint also captures
git diffs. Its own WP; it needs a checkpoint-format contract change.

**Verification boundary:** the offline core (renderer + delta helpers) is
unit-tested on real captured harness output. The live UI-non-regression check
(a real container emitting stream-json, the PWA rendering identical visible text
to the old `--print` path) requires a Docker host + the real `claude` harness
and is the manual end-to-end step, not something the offline suite can assert.
