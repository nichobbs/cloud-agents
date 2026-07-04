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
}

export function useStreamMessage(sessionId: string): StreamState {
  const [output, setOutput] = useState('');
  const [isStreaming, setIsStreaming] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
  }, [sessionId]);

  const send = useCallback(
    async (text: string): Promise<SendResult> => {
      const forSession = sessionId;
      const forGeneration = generationRef.current;
      const stillCurrent = () =>
        activeSessionRef.current === forSession && generationRef.current === forGeneration;

      setIsStreaming(true);
      setError(null);

      // Show user prompt with a cyan prefix marker
      setOutput(prev => prev + `\x1b[1;36m❯ ${text}\x1b[0m\n`);

      let succeeded = true;
      try {
        await api.sendMessage(sessionId, text, chunk => {
          if (stillCurrent()) {
            setOutput(prev => prev + chunk);
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
        if (stillCurrent()) {
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

  return { output, isStreaming, error, send, reset };
}
