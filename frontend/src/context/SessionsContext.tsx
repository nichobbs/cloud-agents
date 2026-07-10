import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { api } from '../lib/api';
import type { Session } from '../types';

interface SessionsContextValue {
  sessions: Session[];
  addSession: (session: Session) => void;
  removeSession: (sessionId: string) => void;
  getSession: (sessionId: string) => Session | undefined;
  updateSession: (sessionId: string, updates: Partial<Session>) => void;
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

  // One-shot hydrate from the server (GET /api/sessions) so sessions survive
  // cleared browser storage / a different device. Local entries win on
  // conflict — they carry `createdAt`, which the server record doesn't.
  useEffect(() => {
    let active = true;
    api
      .listSessions()
      .then(remote => {
        if (!active || remote.length === 0) return;
        setSessions(prev => {
          const known = new Set(prev.map(s => s.sessionId));
          const added: Session[] = remote
            .filter(r => !known.has(r.sessionId))
            .map(r => ({ ...r, createdAt: '' }));
          if (added.length === 0) return prev;
          const next = [...prev, ...added];
          localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
          return next;
        });
      })
      .catch(() => {
        /* offline or older backend without the endpoint — local list stands */
      });
    return () => {
      active = false;
    };
  }, []);

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
    <SessionsContext.Provider value={{ sessions, addSession, removeSession, getSession, updateSession }}>
      {children}
    </SessionsContext.Provider>
  );
}

export function useSessions(): SessionsContextValue {
  const ctx = useContext(SessionsContext);
  if (!ctx) throw new Error('useSessions must be used within SessionsProvider');
  return ctx;
}
