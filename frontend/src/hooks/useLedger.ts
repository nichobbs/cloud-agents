import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../lib/api';
import { applySnapshot, EMPTY_LEDGER, type LedgerState } from '../lib/ledger';

/** Poll cadence while a run streams (the agent is writing to the ledger)
 *  and while idle (only the human, or a scheduled job, changes it). */
export const LEDGER_POLL_ACTIVE_MS = 3000;
export const LEDGER_POLL_IDLE_MS = 10000;

/** Live session-ledger state via cursor polling: one full snapshot, then
 *  `?after=<cursor>` deltas (the server answers `unchanged` cheaply when
 *  nothing moved). Pauses while the tab is hidden. `refresh()` polls now —
 *  call it after the user acts so their change shows immediately. An older
 *  backend without the ledger (404) sets `unavailable` and stops polling. */
export function useLedger(sessionId: string, active: boolean) {
  const [state, setState] = useState<LedgerState>(EMPTY_LEDGER);
  const [loaded, setLoaded] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [error, setError] = useState('');
  const stateRef = useRef(state);
  const sessionRef = useRef(sessionId);
  const inFlight = useRef(false);

  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  const poll = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    const forSession = sessionId;
    try {
      const snap = await api.getLedger(forSession, stateRef.current.cursor);
      if (sessionRef.current !== forSession) return;
      const next = applySnapshot(stateRef.current, snap);
      stateRef.current = next;
      setState(next);
      setLoaded(true);
      setError('');
    } catch (e) {
      if (sessionRef.current !== forSession) return;
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.startsWith('404')) {
        setUnavailable(true);
      } else {
        setError(msg);
      }
    } finally {
      inFlight.current = false;
    }
  }, [sessionId]);

  // A new session starts from a clean, full snapshot.
  useEffect(() => {
    sessionRef.current = sessionId;
    stateRef.current = EMPTY_LEDGER;
    setState(EMPTY_LEDGER);
    setLoaded(false);
    setUnavailable(false);
    setError('');
    void poll();
  }, [sessionId, poll]);

  useEffect(() => {
    if (unavailable) return;
    const id = window.setInterval(
      () => {
        if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
        void poll();
      },
      active ? LEDGER_POLL_ACTIVE_MS : LEDGER_POLL_IDLE_MS,
    );
    return () => window.clearInterval(id);
  }, [poll, active, unavailable]);

  return { state, loaded, unavailable, error, refresh: poll };
}
