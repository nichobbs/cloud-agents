import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../lib/api';

export interface StreamState {
  output: string;
  isStreaming: boolean;
  error: string | null;
  /** Resolves to `false` if the send failed (see `error`), `true` on success. */
  send: (text: string) => Promise<boolean>;
  reset: () => void;
}

export function useStreamMessage(sessionId: string): StreamState {
  const [output, setOutput] = useState('');
  const [isStreaming, setIsStreaming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const activeSessionRef = useRef(sessionId);

  // Reset all stream state whenever the session changes, and stop applying
  // updates from any send() still in flight for the *previous* session. The
  // page component that owns this hook (SessionDetail) isn't remounted on
  // navigation between sessions — only its `sessionId` prop changes — so
  // without this a slow or failed send for session A leaks its output/error
  // into session B's view after navigating away.
  useEffect(() => {
    activeSessionRef.current = sessionId;
    setOutput('');
    setIsStreaming(false);
    setError(null);
  }, [sessionId]);

  const send = useCallback(
    async (text: string): Promise<boolean> => {
      const forSession = sessionId;
      setIsStreaming(true);
      setError(null);

      // Show user prompt with a cyan prefix marker
      setOutput(prev => prev + `\x1b[1;36m❯ ${text}\x1b[0m\n`);

      let succeeded = true;
      try {
        await api.sendMessage(sessionId, text, chunk => {
          if (activeSessionRef.current === forSession) {
            setOutput(prev => prev + chunk);
          }
        });
      } catch (err) {
        succeeded = false;
        const msg = err instanceof Error ? err.message : String(err);
        if (activeSessionRef.current === forSession) {
          setError(msg);
          setOutput(prev => prev + `\x1b[1;31mError: ${msg}\x1b[0m\n`);
        }
      } finally {
        if (activeSessionRef.current === forSession) {
          setIsStreaming(false);
        }
      }
      return succeeded;
    },
    [sessionId],
  );

  const reset = useCallback(() => {
    setOutput('');
    setError(null);
  }, []);

  return { output, isStreaming, error, send, reset };
}
