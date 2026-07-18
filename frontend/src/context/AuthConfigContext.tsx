import { createContext, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { api } from '../lib/api';

interface AuthConfigValue {
  /** null while the initial fetch is in flight. */
  configured: boolean | null;
  clientId: string;
}

const AuthConfigContext = createContext<AuthConfigValue>({ configured: null, clientId: '' });

/// Fetches GET /api/auth/github/config once for the whole app — whether
/// GitHub sign-in is offered, and if so, the client ID to authorize with.
/// Shared by Nav (the sign-in button) and RequireAuth (the route guard) so
/// they agree on the same answer instead of each polling the endpoint
/// separately.
export function AuthConfigProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<AuthConfigValue>({ configured: null, clientId: '' });

  useEffect(() => {
    let active = true;
    api
      .getAuthConfig()
      .then(cfg => {
        if (active) setValue(cfg);
      })
      .catch((err: unknown) => {
        if (!active) return;
        // A 404 (api.ts throws `${status} ${text}`) means an older backend
        // genuinely predates this endpoint — safe to treat as "not
        // configured", matching how Nav always behaved. Any other failure
        // (a real server error, a network blip, a timeout) is NOT safe to
        // conflate with "not configured": doing so would silently open
        // access on a transient backend problem instead of surfacing it.
        // Leave `configured` at its current value (null on first load,
        // i.e. still "loading") so RequireAuth keeps waiting rather than
        // either granting unguarded access or offering Login's sign-in
        // button with no client ID to authorize against.
        if (err instanceof Error && /^404\b/.test(err.message)) {
          setValue({ configured: false, clientId: '' });
        }
      });
    return () => {
      active = false;
    };
  }, []);

  return <AuthConfigContext.Provider value={value}>{children}</AuthConfigContext.Provider>;
}

export function useAuthConfig(): AuthConfigValue {
  return useContext(AuthConfigContext);
}
