import { createContext, useCallback, useContext, useState } from 'react';
import type { ReactNode } from 'react';
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
