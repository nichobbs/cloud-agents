import { useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { api } from '../lib/api';
import { beginLogin, getLogin, isSignedIn, signOut } from '../lib/auth';

export function Nav() {
  const { pathname } = useLocation();
  const isNew = pathname === '/sessions/new';
  const [signedIn, setSignedIn] = useState(isSignedIn);
  const [oauth, setOauth] = useState<{ configured: boolean; clientId: string } | null>(null);

  // Login state can change on other pages (the OAuth callback, a sign-out);
  // re-read it whenever the route changes.
  useEffect(() => {
    setSignedIn(isSignedIn());
  }, [pathname]);

  // Whether the server offers GitHub sign-in (best-effort; older backends
  // without the endpoint just don't show the button).
  useEffect(() => {
    let active = true;
    api
      .getAuthConfig()
      .then(cfg => {
        if (active) setOauth(cfg);
      })
      .catch(() => {
        /* endpoint unavailable — hide the button */
      });
    return () => {
      active = false;
    };
  }, []);

  const handleSignOut = () => {
    signOut();
    setSignedIn(false);
  };

  return (
    <nav style={navStyle}>
      <Link to="/sessions" style={logoStyle}>
        Cloud Agents
      </Link>
      <div style={{ display: 'flex', gap: '12px', alignItems: 'center' }}>
        <Link
          to="/sessions"
          style={{ ...linkStyle, color: pathname === '/sessions' ? '#c9d1d9' : '#8b949e' }}
        >
          Sessions
        </Link>
        <Link
          to="/repos"
          style={{ ...linkStyle, color: pathname === '/repos' ? '#c9d1d9' : '#8b949e' }}
        >
          Repos
        </Link>
        <Link
          to="/prompts"
          style={{ ...linkStyle, color: pathname === '/prompts' ? '#c9d1d9' : '#8b949e' }}
        >
          Prompts
        </Link>
        <Link
          to="/profiles"
          style={{ ...linkStyle, color: pathname === '/profiles' ? '#c9d1d9' : '#8b949e' }}
        >
          Profiles
        </Link>
        <Link
          to="/credentials"
          style={{ ...linkStyle, color: pathname === '/credentials' ? '#c9d1d9' : '#8b949e' }}
        >
          Credentials
        </Link>
        <Link
          to="/integrations"
          style={{ ...linkStyle, color: pathname === '/integrations' ? '#c9d1d9' : '#8b949e' }}
        >
          Integrations
        </Link>
        <Link
          to="/webhooks"
          style={{ ...linkStyle, color: pathname === '/webhooks' ? '#c9d1d9' : '#8b949e' }}
        >
          Webhooks
        </Link>
        <Link
          to="/sessions/new"
          style={{
            ...btnStyle,
            background: isNew ? '#1f6feb' : '#21262d',
            borderColor: isNew ? '#1f6feb' : '#30363d',
          }}
        >
          New session
        </Link>
        {signedIn ? (
          <span style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
            <span style={loginStyle} title="Signed in with GitHub">
              {getLogin()}
            </span>
            <button style={signOutBtnStyle} onClick={handleSignOut} title="Forget the GitHub sign-in on this device">
              Sign out
            </button>
          </span>
        ) : (
          oauth?.configured && (
            <button
              style={signInBtnStyle}
              onClick={() => beginLogin(oauth.clientId)}
              title="Sign in with GitHub (OAuth)"
            >
              Sign in with GitHub
            </button>
          )
        )}
      </div>
    </nav>
  );
}

const navStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  padding: '12px 24px',
  borderBottom: '1px solid #21262d',
  background: '#0d1117',
  position: 'sticky',
  top: 0,
  zIndex: 10,
};

const logoStyle: React.CSSProperties = {
  fontWeight: 700,
  fontSize: '15px',
  color: '#c9d1d9',
  textDecoration: 'none',
  letterSpacing: '-0.01em',
};

const linkStyle: React.CSSProperties = {
  fontSize: '14px',
  textDecoration: 'none',
};

const btnStyle: React.CSSProperties = {
  fontSize: '13px',
  padding: '5px 12px',
  borderRadius: '6px',
  border: '1px solid',
  color: '#c9d1d9',
  textDecoration: 'none',
  cursor: 'pointer',
};

const loginStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#56d364',
};

const signInBtnStyle: React.CSSProperties = {
  fontSize: '13px',
  padding: '5px 12px',
  borderRadius: '6px',
  border: '1px solid #30363d',
  background: '#21262d',
  color: '#c9d1d9',
  cursor: 'pointer',
};

const signOutBtnStyle: React.CSSProperties = {
  fontSize: '12px',
  padding: '3px 10px',
  borderRadius: '6px',
  border: '1px solid #30363d',
  background: 'transparent',
  color: '#8b949e',
  cursor: 'pointer',
};
