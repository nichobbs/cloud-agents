import { useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { useAuthConfig } from '../context/AuthConfigContext';
import { AUTH_CHANGED_EVENT, isSignedIn } from '../lib/auth';

/// Wraps a route element: redirects to /login when GitHub sign-in is
/// configured on this deployment and the device isn't signed in.
///
/// When sign-in isn't configured at all (no CLOUD_AGENTS_GITHUB_CLIENT_ID/
/// _SECRET set), renders children unguarded instead — matching the
/// backend's own "open access when unconfigured" behavior (auth.l) rather
/// than stranding every user behind a login page with no way to actually
/// sign in.
export function RequireAuth({ children }: { children: ReactNode }) {
  const location = useLocation();
  const { configured } = useAuthConfig();
  const [signedIn, setSignedIn] = useState(isSignedIn);

  // Sign-out can happen without a route change (the nav bar's button on the
  // current page), so react to the explicit event rather than only
  // re-checking on navigation.
  useEffect(() => {
    const refresh = () => setSignedIn(isSignedIn());
    window.addEventListener(AUTH_CHANGED_EVENT, refresh);
    return () => window.removeEventListener(AUTH_CHANGED_EVENT, refresh);
  }, []);

  // Still waiting to learn whether GitHub sign-in is even offered — show the
  // same loading placeholder every other data-fetching page uses (Prompts,
  // Profiles, Credentials) rather than flashing protected content or
  // redirecting prematurely.
  if (configured === null) return <div style={mutedStyle}>Loading…</div>;

  if (!configured || signedIn) return <>{children}</>;

  return <Navigate to="/login" state={{ from: location }} replace />;
}

const mutedStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#6e7681',
  textAlign: 'center',
  padding: '16px',
};
