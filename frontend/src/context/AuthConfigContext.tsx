import { createContext, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { api } from '../lib/api';

interface AuthConfigValue {
  /** null while the initial fetch is in flight. */
  configured: boolean | null;
  clientId: string;
}

const AuthConfigContext = createContext<AuthConfigValue>({ configured: null, clientId: '' });

const RETRY_DELAY_MS = 5000;

/// Fetches GET /api/auth/github/config once for the whole app — whether
/// GitHub sign-in is offered, and if so, the client ID to authorize with.
/// Shared by Nav (the sign-in button) and RequireAuth (the route guard) so
/// they agree on the same answer instead of each polling the endpoint
/// separately.
export function AuthConfigProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<AuthConfigValue>({ configured: null, clientId: '' });

  useEffect(() => {
    let active = true;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;

    const attempt = () => {
      api
        .getAuthConfig()
        .then(cfg => {
          if (active) setValue(cfg);
        })
        .catch((err: unknown) => {
          if (!active) return;
          // A 404 (api.ts throws `${status} ${text}`) means an older
          // backend genuinely predates this endpoint — safe to treat as
          // "not configured", matching how Nav always behaved.
          if (err instanceof Error && /^404\b/.test(err.message)) {
            setValue({ configured: false, clientId: '' });
            return;
          }
          // Any other failure (a real server error, a network blip, a
          // timeout) is NOT safe to conflate with "not configured": doing
          // so would silently open access on a transient backend problem
          // instead of surfacing it. But leaving `configured` at null
          // forever would strand a signed-out user on an indefinite
          // "Loading…" across every guarded route — retry until the
          // backend recovers or this unmounts, instead.
          retryTimer = setTimeout(attempt, RETRY_DELAY_MS);
        });
    };

    attempt();

    return () => {
      active = false;
      clearTimeout(retryTimer);
    };
  }, []);

  return <AuthConfigContext.Provider value={value}>{children}</AuthConfigContext.Provider>;
}

export function useAuthConfig(): AuthConfigValue {
  return useContext(AuthConfigContext);
}
