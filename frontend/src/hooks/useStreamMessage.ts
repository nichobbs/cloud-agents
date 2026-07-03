import { useCallback, useRef, useState } from 'react';
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
  const cancelledRef = useRef(false);

  const send = useCallback(
    async (text: string): Promise<boolean> => {
      setIsStreaming(true);
      setError(null);
      cancelledRef.current = false;

      // Show user prompt with a cyan prefix marker
      setOutput(prev => prev + `\x1b[1;36m❯ ${text}\x1b[0m\n`);

      let succeeded = true;
      try {
        await api.sendMessage(sessionId, text, chunk => {
          if (!cancelledRef.current) {
            setOutput(prev => prev + chunk);
          }
        });
      } catch (err) {
        succeeded = false;
        const msg = err instanceof Error ? err.message : String(err);
        setError(msg);
        setOutput(prev => prev + `\x1b[1;31mError: ${msg}\x1b[0m\n`);
      } finally {
        if (!cancelledRef.current) {
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
