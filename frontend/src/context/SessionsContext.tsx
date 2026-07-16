import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { api } from '../lib/api';
import type { Session } from '../types';

interface SessionsContextValue {
  sessions: Session[];
  addSession: (session: Session) => void;
  removeSession: (sessionId: string) => void;
  getSession: (sessionId: string) => Session | undefined;
  updateSession: (sessionId: string, updates: Partial<Session>) => void;
  refreshSessions: () => Promise<void>;
}

const SessionsContext = createContext<SessionsContextValue | null>(null);

const STORAGE_KEY = 'cloud_agents_sessions';

function load(): Session[] {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]') as Session[];
  } catch {
    return [];
  }
}

export function SessionsProvider({ children }: { children: ReactNode }) {
  const [sessions, setSessions] = useState<Session[]>(load);

  // Hydrate from the server (GET /api/sessions) so sessions survive cleared
  // browser storage / a different device, and merge the server's bookkeeping
  // fields (status, createdAt, lastMessageAt) into known entries so the list
  // can show live status and real timestamps. A locally-stored createdAt is
  // kept when the server doesn't send one (older backend).
  // Guards the awaited continuation below: a refresh still in flight when the
  // provider unmounts (tests, HMR) must not call setSessions afterwards.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const refreshSessions = useCallback(async () => {
    const remote = await api.listSessions();
    if (remote.length === 0 || !mountedRef.current) return;
    setSessions(prev => {
      const byId = new Map(prev.map(s => [s.sessionId, s]));
      let changed = false;
      const merged: Session[] = remote.map(r => {
        const local = byId.get(r.sessionId);
        byId.delete(r.sessionId);
        const next: Session = {
          ...local,
          ...r,
          createdAt: r.createdAt || local?.createdAt || '',
        };
        if (JSON.stringify(next) !== JSON.stringify(local)) changed = true;
        return next;
      });
      // Local-only entries (older backend without the list endpoint, or a
      // create raced against this refresh) stay at the front.
      const localOnly = [...byId.values()];
      if (localOnly.length > 0) changed = true;
      if (!changed && merged.length === prev.length) return prev;
      const next = [...localOnly, ...merged];
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }, []);

  useEffect(() => {
    let active = true;
    const tick = () => {
      refreshSessions().catch(() => {
        /* offline or older backend without the endpoint — local list stands */
      });
    };
    tick();
    // Keep session status/last-active fresh while the app is open — cheap
    // (one small GET) and makes RUNNING badges on the list trustworthy.
    const interval = setInterval(() => {
      if (active) tick();
    }, 15_000);
    return () => {
      active = false;
      clearInterval(interval);
    };
  }, [refreshSessions]);

  const addSession = useCallback((session: Session) => {
    setSessions(prev => {
      const next = [session, ...prev];
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }, []);

  const removeSession = useCallback((sessionId: string) => {
    setSessions(prev => {
      const next = prev.filter(s => s.sessionId !== sessionId);
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }, []);

  const getSession = useCallback(
    (sessionId: string) => sessions.find(s => s.sessionId === sessionId),
    [sessions],
  );

  const updateSession = useCallback((sessionId: string, updates: Partial<Session>) => {
    setSessions(prev => {
      const next = prev.map(s => s.sessionId === sessionId ? { ...s, ...updates } : s);
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }, []);

  return (
    <SessionsContext.Provider
      value={{ sessions, addSession, removeSession, getSession, updateSession, refreshSessions }}
    >
      {children}
    </SessionsContext.Provider>
  );
}

export function useSessions(): SessionsContextValue {
  const ctx = useContext(SessionsContext);
  if (!ctx) throw new Error('useSessions must be used within SessionsProvider');
  return ctx;
}
