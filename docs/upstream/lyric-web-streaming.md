# Feature request: chunked/streamed HTTP responses in Lyric.Web

> **Status: ready to file.** This document is written to be filed verbatim as
> a `lyric-lang` issue against Lyric.Web by the maintainer (this session
> cannot file it). Written against `Lyric.Web` 0.4.26, the version pinned in
> this repo's `lyric.toml`.

## Summary

`Lyric.Web` handlers can only return a single, complete `Web.Response`. There
is no way to begin sending a response before the handler returns, to flush
intermediate bytes, or to hand the framework an iterator/generator of body
chunks. Any endpoint whose result is produced incrementally over a long time
(process output, log tailing, progress reporting, LLM tokens) must therefore
buffer everything, hold the connection silently until the work finishes, and
emit the whole body at once. Please add a first-class way for a handler to
stream a response body incrementally.

## Current behaviour (0.4.26)

The 0.4.26 `Handler`/`Middleware` model dispatches each request to
`func handle(req: in Web.Request): Web.Response`. The `Web.Response` carries a
complete body string; the framework serialises and writes it only after
`handle` returns. Consequences observed in a real application
(nichobbs/cloud-agents, an agent-session server whose core endpoint runs a
Docker container that emits output continuously for up to 30 minutes):

1. **The send blocks for the whole run.** `POST /api/sessions/{id}/messages`
   (`sendMessage` in `src/handlers/sessions.l`) cannot return until the
   container finishes — up to the 30-minute hard cap in
   `src/docker_manager.l` (`taskWaitMs(t, 1800000)`). The client sees zero
   bytes for the entire duration.
2. **The "SSE" the app emits is a post-hoc replay, not a stream.** The
   response body is formatted as Server-Sent Events frames
   (`CloudAgents.Streaming.formatLogsAsSse`), but every frame is generated
   from the *captured* log after the run completes and delivered in one
   buffered body. The SSE format is only used so the client-side parser has
   stable framing; nothing about it is live.
3. **Polling is the only live-output mechanism.** Because the response cannot
   stream, the frontend polls a second endpoint while the send is
   outstanding:
   - `GET /api/sessions/{id}/output` (`getRunOutput` in
     `src/handlers/sessions.l`) returns the **entire** container log on every
     poll tick (every 1.5–6 s), so a chatty hour-long run re-transfers its
     whole accumulated log dozens of times.
   - `GET /api/sessions/{id}/output/{offset}` (`getRunOutputFrom`, added to
     mitigate exactly this) returns only the bytes past a client-supplied
     offset. This cuts steady-state transfer to O(new output), but it is
     still polling: 1.5–6 s of added latency per chunk, one full
     request/response (auth, routing, status + container lookups, a Docker
     `logs` call) per tick, and a resync protocol for log truncation — all
     workaround machinery that true streaming would delete.

## What is being asked for

A supported way for a handler to produce a response body incrementally. Either
of the following API shapes (or an equivalent) would unblock this project;
both are listed so the maintainers can pick what fits Lyric.Web's design:

### Option A: a response-writer / flush handle

```lyric
// sketch — names illustrative
impl Web.StreamingHandler for RouteSendMessage {
  func handle(req: in Web.Request, w: in Web.ResponseWriter): Unit {
    Web.writeStatus(w, 200)
    Web.writeHeader(w, "Content-Type", "text/event-stream")
    // called repeatedly, from async code, while the work runs:
    Web.writeChunk(w, "data: {\"chunk\":\"...\"}\n\n")
    Web.flush(w)
    ...
    Web.finish(w)
  }
}
```

The handler pushes chunks; each `flush` makes the bytes visible to the client
(chunked transfer encoding or equivalent). This is the `http.ResponseWriter` /
ASP.NET `HttpResponse.Body` shape.

### Option B: an async chunk iterator on Web.Response

```lyric
// sketch — names illustrative
pub func handle(req: in Web.Request): Web.Response {
  // body is produced by an async iterator the framework drains as chunks
  return Web.streaming(200, "text/event-stream", chunkSource)
}
```

Where `chunkSource` is an async iterator/channel of `String` (or bytes) the
framework awaits and writes as each chunk becomes available. This shape keeps
`Handler`'s return-a-value signature.

### Requirements common to both

- Chunks written before the handler completes MUST reach the client without
  waiting for the handler to finish (i.e. genuine `Transfer-Encoding:
  chunked` or equivalent, with any internal buffering flushable).
- Usable from `async func` handler bodies — the producing work here is
  `await`-heavy (Docker attach/logs).
- Headers and status are committed at first write; attempting to change them
  after MUST be a defined error, not silence.
- Client disconnect must be observable (an error or cancellation on write) so
  the producer can stop the underlying work instead of streaming into the
  void for 30 minutes.
- The existing complete-`Web.Response` path must keep working unchanged —
  streaming should be opt-in per route/handler.

## Acceptance criteria

1. A handler can send an initial chunk, wait (e.g. `await` a timer or a
   Docker log read), send another chunk, and a `curl -N` client observes the
   first chunk *before* the second is produced.
2. An SSE endpoint (`Content-Type: text/event-stream`) implemented this way
   delivers each `data:` frame to a browser `EventSource`/`fetch`-reader as
   it is written, with no framework-imposed full-body buffering.
3. A streaming response of unbounded/unknown length does not require a
   `Content-Length` up front.
4. When the client disconnects mid-stream, the handler's next write fails (or
   its cancellation token fires) within a bounded time.
5. Non-streaming handlers (`func handle(req): Web.Response`) compile and
   behave exactly as in 0.4.26.

## Net effect for this project once available

`sendMessage` would stream the container's output as real SSE frames while
the run executes; the frontend's dual-loop polling in
`frontend/src/hooks/useStreamMessage.ts`, both `/output` endpoints'
poll-tick Docker `logs` calls, the offset/resync protocol, and the
post-hoc SSE replay in `CloudAgents.Streaming` all become deletable
compatibility code.
