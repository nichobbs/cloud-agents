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
/// separately. An older backend without the endpoint, or a network hiccup,
/// resolves to "not configured" rather than blocking the app.
export function AuthConfigProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<AuthConfigValue>({ configured: null, clientId: '' });

  useEffect(() => {
    let active = true;
    api
      .getAuthConfig()
      .then(cfg => {
        if (active) setValue(cfg);
      })
      .catch(() => {
        if (active) setValue({ configured: false, clientId: '' });
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
