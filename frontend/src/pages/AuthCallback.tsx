import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { api } from '../lib/api';
import { completeLogin, takeReturnPath, takeStoredState } from '../lib/auth';

/// GitHub redirects here with ?code=…&state=… after the user authorizes the
/// app. Verify the state matches the one this device generated (CSRF
/// binding), exchange the one-time code server-side, persist the grant, and
/// land on the repo browser — which the fresh token immediately powers.
export function AuthCallback() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const [error, setError] = useState('');
  // React 18 StrictMode double-invokes effects; the code is single-use, so
  // the second invocation must not re-run the exchange.
  const startedRef = useRef(false);

  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;

    const code = searchParams.get('code') ?? '';
    const state = searchParams.get('state') ?? '';
    const ghError = searchParams.get('error_description') ?? searchParams.get('error') ?? '';
    if (ghError) {
      setError(`GitHub reported: ${ghError}`);
      return;
    }
    if (!code) {
      setError('No authorization code in the callback URL.');
      return;
    }
    const expected = takeStoredState();
    if (!expected || state !== expected) {
      setError('OAuth state mismatch — the login round trip did not start on this device. Try signing in again.');
      return;
    }
    api
      .exchangeCode(code)
      .then(({ token, login }) => {
        completeLogin(token, login);
        // Send the user back to wherever RequireAuth redirected them from;
        // falls back to /repos when sign-in didn't originate from a guard
        // redirect (e.g. the nav bar's button).
        navigate(takeReturnPath() || '/repos', { replace: true });
      })
      .catch(err => {
        setError(err instanceof Error ? err.message : 'Token exchange failed');
      });
  }, [searchParams, navigate]);

  return (
    <div style={pageStyle}>
      {!error && <div style={mutedStyle}>Completing GitHub sign-in…</div>}
      {error && (
        <div>
          <div style={errStyle}>Sign-in failed: {error}</div>
          <div style={{ marginTop: '12px' }}>
            <Link to="/sessions" style={{ color: '#58a6ff' }}>
              Back to sessions
            </Link>
          </div>
        </div>
      )}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '520px',
  margin: '0 auto',
  padding: '48px 24px',
  textAlign: 'center',
};

const mutedStyle: React.CSSProperties = { color: '#8b949e', fontSize: '14px' };

const errStyle: React.CSSProperties = { color: '#f85149', fontSize: '14px' };
