import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../lib/api';
import { applySnapshot, EMPTY_LEDGER, type LedgerState } from '../lib/ledger';

/** Poll cadence while a run streams (the agent is writing to the ledger)
 *  and while idle (only the human, or a scheduled job, changes it). */
export const LEDGER_POLL_ACTIVE_MS = 3000;
export const LEDGER_POLL_IDLE_MS = 10000;

/** Live session-ledger state via cursor polling: one full snapshot, then
 *  `?after=<cursor>` deltas (the server answers `unchanged` cheaply when
 *  nothing moved). Pauses while the tab is hidden and catches up the moment
 *  it is shown again or a run ends. `refresh()` polls now —
 *  call it after the user acts so their change shows immediately. An older
 *  backend without the ledger (404) sets `unavailable` and stops polling. */
export function useLedger(sessionId: string, active: boolean) {
  const [state, setState] = useState<LedgerState>(EMPTY_LEDGER);
  const [loaded, setLoaded] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [error, setError] = useState('');
  const stateRef = useRef(state);
  const sessionRef = useRef(sessionId);
  // The session a poll is in flight for ('' = none), and whether another
  // poll was asked for meanwhile (a refresh() after the user acted must not
  // be swallowed by a poll that started before the action landed).
  const inFlight = useRef('');
  const again = useRef(false);

  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  const poll = useCallback(async () => {
    const forSession = sessionId;
    if (inFlight.current === forSession) {
      again.current = true;
      return;
    }
    inFlight.current = forSession;
    again.current = false;
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
      // The status ApiError carries (read structurally, so a test double of
      // the api module needn't provide the class).
      if ((e as { status?: unknown } | null)?.status === 404) {
        setUnavailable(true);
      } else {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      if (inFlight.current === forSession) inFlight.current = '';
    }
    if (again.current && sessionRef.current === forSession) {
      again.current = false;
      await poll();
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

  // Catch up at once when the tab comes back into view: polls were skipped
  // while it was hidden.
  useEffect(() => {
    if (unavailable || typeof document === 'undefined') return;
    const onVisible = () => {
      if (document.visibilityState === 'visible') void poll();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [poll, unavailable]);

  // A run that just ended wrote its last entries after the previous fast
  // poll; fetch them now instead of waiting a whole idle interval.
  const wasActive = useRef(active);
  useEffect(() => {
    if (wasActive.current && !active && !unavailable) void poll();
    wasActive.current = active;
  }, [active, poll, unavailable]);

  return { state, loaded, unavailable, error, refresh: poll };
}
