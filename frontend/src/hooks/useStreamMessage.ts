import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../lib/api';

export interface SendResult {
  /** `false` if the send failed (see `error`), `true` on success. */
  succeeded: boolean;
  /**
   * `true` if, by the time this send settled, it was no longer the current
   * send for this hook instance — either the session changed, or the user
   * left and returned to this *same* session before this send resolved (a
   * fresh generation). Callers should treat a stale result as "ignore me":
   * this hook's own output/isStreaming/error state has already discarded
   * it, and any caller-side continuation (reload a transcript, reset local
   * UI state, steal focus) should bail out too, rather than acting on a
   * completed-but-superseded send.
   */
  stale: boolean;
}

export interface StreamState {
  output: string;
  isStreaming: boolean;
  error: string | null;
  send: (text: string) => Promise<SendResult>;
  reset: () => void;
  /**
   * Incremented each time a run this hook *reattached to* (via the mount-time
   * resume, not a local send()) finishes. The owner watches it to fold the
   * finished run into the transcript — the same post-run handling send() gets
   * from its caller — so a reattached run's output doesn't vanish on
   * completion (#316). Never bumped for a locally-initiated send() (its caller
   * already handles that) or for a cancelled/superseded reattach.
   */
  reattachEnded: number;
}

export function useStreamMessage(sessionId: string): StreamState {
  const [output, setOutput] = useState('');
  const [isStreaming, setIsStreaming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Bumped when a reattached run finishes so the owner can fold it into the
  // transcript (#316); see StreamState.reattachEnded.
  const [reattachEnded, setReattachEnded] = useState(0);
  // True while a local send() is running. The reattach resume() yields to it so
  // the two don't both drive output/isStreaming if a send starts in the narrow
  // window before resume()'s first getRunOutput resolves (#317).
  const sendInFlightRef = useRef(false);
  const activeSessionRef = useRef(sessionId);

  // Bumped every time `sessionId` changes, including a return trip to a
  // session already visited earlier. This is what lets `send()` tell apart
  // "the session changed" from "we're back on the same session, but this is
  // a stale request from a previous visit" — checking `activeSessionRef`
  // alone isn't enough for that second case, since the session id is
  // identical both times. Without it, navigating away from session A mid-send
  // and back to A, then sending a *new* message, could have the abandoned
  // first send's `finally` clause fire after the second send's and
  // incorrectly flip `isStreaming` back to false while the second send is
  // still genuinely in flight.
  const generationRef = useRef(0);

  // Reset all stream state whenever the session changes, and stop applying
  // updates from any send() still in flight for the *previous* session. The
  // page component that owns this hook (SessionDetail) isn't remounted on
  // navigation between sessions — only its `sessionId` prop changes — so
  // without this a slow or failed send for session A leaks its output/error
  // into session B's view after navigating away.
  useEffect(() => {
    activeSessionRef.current = sessionId;
    generationRef.current += 1;
    setOutput('');
    setIsStreaming(false);
    setError(null);
    // Clear the send-in-flight guard on navigation too (#318): a send for the
    // previous session is now stale, and leaving it set would block the new
    // session's reattach from ever showing live output until that abandoned
    // (possibly minutes-long) send finally settles.
    sendInFlightRef.current = false;
  }, [sessionId]);

  // Reattach to a run already in progress for this session. send() only polls
  // for runs it started, so a page reload or a second tab (no send() driving
  // the poll) would show nothing until the run finished (#217). Runs after the
  // reset effect above (declaration order), so it re-populates what reset just
  // cleared only when there genuinely is a running run. Guarded by the same
  // session id + generation as send(), plus a `cancelled` flag for unmount.
  useEffect(() => {
    const forSession = sessionId;
    const forGeneration = generationRef.current;
    let cancelled = false;
    const alive = () =>
      !cancelled &&
      activeSessionRef.current === forSession &&
      generationRef.current === forGeneration;

    const resume = async () => {
      let first: { running: boolean; output: string };
      try {
        first = await api.getRunOutput(forSession);
      } catch {
        return; // no run in progress / endpoint unavailable
      }
      // Yield to a send() that started during the initial check — it owns the
      // stream from here, so don't double-drive output/isStreaming (#317).
      if (!alive() || sendInFlightRef.current || !first.running) return;
      setIsStreaming(true);
      let last = first.output;
      // Server-authoritative offset for the incremental endpoint: the initial
      // probe returned the full log, so subsequent polls only need the bytes
      // past it. The server echoes back its current total as `length`, which
      // becomes the next offset.
      let offset = first.output.length;
      // Prefer the incremental endpoint; on the first throw (older backend
      // without the /output/{offset} route) fall back to full-log polling for
      // the rest of this run.
      let deltaSupported = true;
      if (last) setOutput(last);
      let delay = 1500;
      const maxDelay = 6000;
      let finished = false;
      while (alive()) {
        await new Promise(r => setTimeout(r, delay));
        if (!alive()) return;
        try {
          let running: boolean;
          let next: string;
          if (deltaSupported) {
            try {
              const d = await api.getRunOutputDelta(forSession, offset);
              running = d.running;
              if (!d.running && d.length === 0) {
                // The endpoint's not-running SENTINEL ({running:false,
                // length:0, chunk:""}) is a status signal, not log data —
                // treating its length as a truncation resync would blank the
                // just-produced output on every completed run (#440; the
                // pre-delta code guarded this with `next.output &&`). Keep
                // the accumulated output untouched.
                next = last;
              } else if (d.length < offset) {
                // A shorter (but real) log means it was truncated/replaced
                // (new run): the chunk is the full new log — replace instead
                // of appending (resync).
                next = d.chunk;
                offset = d.length;
              } else {
                next = last + d.chunk;
                offset = d.length;
              }
            } catch {
              deltaSupported = false;
              const full = await api.getRunOutput(forSession);
              running = full.running;
              // Same sentinel rule for the legacy endpoint: an empty full log
              // never overwrites accumulated output (#440).
              next = full.output ? full.output : last;
            }
          } else {
            const full = await api.getRunOutput(forSession);
            running = full.running;
            next = full.output ? full.output : last;
          }
          if (!alive()) return;
          if (next !== last) {
            last = next;
            setOutput(last);
            delay = 1500; // fresh output — poll responsively again (#216)
          }
          if (!running) {
            finished = true;
            break;
          }
        } catch {
          // ignore transient poll failures
        }
        delay = Math.min(Math.round(delay * 1.5), maxDelay);
      }
      if (alive()) {
        setIsStreaming(false);
        // The reattached run actually finished (vs. we were cancelled) — signal
        // the owner to fold it into the transcript so its output doesn't vanish
        // (#316).
        if (finished) setReattachEnded(n => n + 1);
      }
    };
    void resume();
    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  const send = useCallback(
    async (text: string): Promise<SendResult> => {
      const forSession = sessionId;
      const forGeneration = generationRef.current;
      const stillCurrent = () =>
        activeSessionRef.current === forSession && generationRef.current === forGeneration;

      sendInFlightRef.current = true; // let a concurrent reattach yield to us (#317)
      setIsStreaming(true);
      setError(null);

      // Show user prompt with a cyan prefix marker, and capture everything on
      // screen up to and including it as this send's immutable base. The poll
      // below rebuilds only the live-tail region on top of `base`, so output
      // accumulated by earlier sends is preserved rather than wiped.
      const marker = `\x1b[1;36m❯ ${text}\x1b[0m\n`;
      let base = marker;
      setOutput(prev => {
        base = prev + marker;
        return base;
      });

      // The backend now streams the run's output as live SSE `data:` frames
      // (Lyric.Web 0.4.33 streaming handler — src/handlers/sessions.l
      // streamSendMessage), delivered via api.sendMessage's onChunk below. This
      // parallel poll is now only a BRIDGE for the brief window before the first
      // real chunk arrives (container startup/clone) and a FALLBACK for an older
      // backend that still buffers. The incremental endpoint (getRunOutputDelta)
      // is preferred: each tick only the bytes past the server-acknowledged
      // offset travel, and the accumulated tail is rebuilt as `base + liveTail`;
      // earlier content in `base` is never overwritten. On an older backend
      // without the delta route the first delta call throws and polling falls
      // back to the full-log endpoint. Polling stops the instant a real streamed
      // chunk arrives (see `polling = false` below) or the run reports finished.
      // Failures are swallowed — polling is best-effort and must never fail the send.
      let polling = true;
      let liveTail = '';
      // Server-authoritative offset for the delta endpoint: the next poll asks
      // only for log bytes past this point; the server's returned `length`
      // becomes the next offset.
      let liveOffset = 0;
      let deltaSupported = true;
      // Poll responsively at first, then back off toward a cap so a long,
      // quiet run doesn't re-poll every 1.5s for its whole duration (#216).
      // The interval resets to 1.5s whenever new output arrives, so an
      // actively-producing run stays responsive.
      const minPollMs = 1500;
      const maxPollMs = 6000;
      let pollDelay = minPollMs;
      const poll = async () => {
        while (polling && stillCurrent()) {
          try {
            let running: boolean;
            let next: string;
            if (deltaSupported) {
              try {
                const d = await api.getRunOutputDelta(sessionId, liveOffset);
                running = d.running;
                if (!d.running && d.length === 0) {
                  // Not-running sentinel, not log data — never let it blank
                  // the accumulated tail (#440; the pre-delta code guarded
                  // this with `partial &&`).
                  next = liveTail;
                } else if (d.length < liveOffset) {
                  // A shorter (but real) log was truncated/replaced (new
                  // run): the chunk is the full new log — replace the
                  // accumulated tail instead of appending (resync).
                  next = d.chunk;
                  liveOffset = d.length;
                } else {
                  next = liveTail + d.chunk;
                  liveOffset = d.length;
                }
              } catch {
                // Older backend without the delta route (or, in tests, an api
                // mock that doesn't define getRunOutputDelta) — fall back to
                // full-log polling for the rest of this run.
                deltaSupported = false;
                const full = await api.getRunOutput(sessionId);
                running = full.running;
                next = full.output ? full.output : liveTail;
              }
            } else {
              const full = await api.getRunOutput(sessionId);
              running = full.running;
              // An empty full log (the endpoint's not-running response) never
              // overwrites the accumulated tail (#440).
              next = full.output ? full.output : liveTail;
            }
            if (!polling || !stillCurrent()) break;
            if (next !== liveTail) {
              liveTail = next;
              setOutput(base + next);
              pollDelay = minPollMs;
            }
            if (!running) break;
          } catch {
            // ignore transient poll failures
          }
          await new Promise(r => setTimeout(r, pollDelay));
          pollDelay = Math.min(Math.round(pollDelay * 1.5), maxPollMs);
        }
      };
      void poll();

      let succeeded = true;
      let firstRealChunk = true;
      try {
        await api.sendMessage(sessionId, text, chunk => {
          polling = false; // real streamed chunks win over polling
          if (stillCurrent()) {
            if (firstRealChunk) {
              // The authoritative stream now owns the live tail. Drop whatever
              // the poll bridge rendered back to `base` and start the tail from
              // this first real chunk, so the stream replaces the polled copy
              // instead of appending a duplicate. Subsequent chunks append. (On
              // an older buffered backend the first "chunk" is the whole log,
              // and this same reset still produces the right result.)
              firstRealChunk = false;
              setOutput(base + chunk);
            } else {
              setOutput(prev => prev + chunk);
            }
          }
        });
      } catch (err) {
        succeeded = false;
        const msg = err instanceof Error ? err.message : String(err);
        if (stillCurrent()) {
          setError(msg);
          setOutput(prev => prev + `\x1b[1;31mError: ${msg}\x1b[0m\n`);
        }
      } finally {
        polling = false;
        // Only clear the guard if this send is still the current one — a stale
        // send resolving after navigation must not clear a flag that now
        // belongs to a newer send (the reset effect already cleared ours on
        // navigation) (#318).
        if (stillCurrent()) {
          sendInFlightRef.current = false;
          setIsStreaming(false);
        }
      }
      return { succeeded, stale: !stillCurrent() };
    },
    [sessionId],
  );

  const reset = useCallback(() => {
    setOutput('');
    setError(null);
  }, []);

  return { output, isStreaming, error, send, reset, reattachEnded };
}
