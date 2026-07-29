import { Navigate, useLocation } from 'react-router-dom';
import type { Location } from 'react-router-dom';
import { useAuthConfig } from '../context/AuthConfigContext';
import { beginLogin, isSignedIn, setReturnPath } from '../lib/auth';

/// Landing page RequireAuth sends signed-out users to. Also reachable
/// directly (e.g. a bookmarked /login) — safe to show even when already
/// signed in, since it just forwards on to wherever the user was headed.
export function Login() {
  const location = useLocation();
  const from = (location.state as { from?: Location } | null)?.from;
  const fromPath = from ? `${from.pathname}${from.search}` : '';
  const { configured, clientId } = useAuthConfig();

  if (isSignedIn()) {
    return <Navigate to={fromPath || '/sessions'} replace />;
  }

  const handleSignIn = () => {
    // Only remember an explicit redirect origin — sign-in triggered some
    // other way (e.g. the nav bar button) has no "from" and should keep
    // falling back to AuthCallback's own default.
    if (fromPath) setReturnPath(fromPath);
    beginLogin(clientId);
  };

  return (
    <div style={pageStyle}>
      <h1 style={titleStyle}>Cloud Agents</h1>
      {configured === null && <div style={mutedStyle}>Loading…</div>}
      {configured === false && (
        <div style={mutedStyle}>
          GitHub sign-in isn&rsquo;t configured on this deployment.
        </div>
      )}
      {configured === true && (
        <>
          <div style={mutedStyle}>Sign in with GitHub to continue.</div>
          <button style={signInBtnStyle} onClick={handleSignIn}>
            Sign in with GitHub
          </button>
        </>
      )}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '360px',
  margin: '80px auto 0',
  padding: '32px 24px',
  textAlign: 'center',
  display: 'flex',
  flexDirection: 'column',
  gap: '16px',
  alignItems: 'center',
};

const titleStyle: React.CSSProperties = {
  fontSize: '20px',
  fontWeight: 700,
  color: '#c9d1d9',
  margin: 0,
};

const mutedStyle: React.CSSProperties = { color: '#8b949e', fontSize: '14px' };

const signInBtnStyle: React.CSSProperties = {
  fontSize: '14px',
  padding: '8px 16px',
  borderRadius: '6px',
  border: '1px solid #30363d',
  background: '#21262d',
  color: '#c9d1d9',
  cursor: 'pointer',
};
