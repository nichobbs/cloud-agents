import { useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useAuthConfig } from '../context/AuthConfigContext';
import { beginLogin, getLogin, isSignedIn, signOut } from '../lib/auth';

const NAV_ITEMS: Array<{ to: string; label: string }> = [
  { to: '/sessions', label: 'Sessions' },
  { to: '/repos', label: 'Repos' },
  { to: '/prompts', label: 'Prompts' },
  { to: '/profiles', label: 'Profiles' },
  { to: '/library', label: 'Library' },
  { to: '/credentials', label: 'Credentials' },
  { to: '/integrations', label: 'Integrations' },
  { to: '/webhooks', label: 'Webhooks' },
];

export function Nav() {
  const { pathname } = useLocation();
  const isNew = pathname === '/sessions/new';
  const [signedIn, setSignedIn] = useState(isSignedIn);
  // Below the .nav-toggle breakpoint (see styles.css), the link list is a
  // collapsible panel instead of a row — this is its open/closed state.
  const [menuOpen, setMenuOpen] = useState(false);
  // Whether the server offers GitHub sign-in — shared with RequireAuth so
  // both agree on the same answer instead of each polling the endpoint
  // separately (best-effort; older backends without the endpoint just
  // resolve to "not configured", hiding the button).
  const { configured, clientId } = useAuthConfig();

  // Login state can change on other pages (the OAuth callback, a sign-out);
  // re-read it whenever the route changes. A route change also means a nav
  // link was just followed, so close the mobile menu too.
  useEffect(() => {
    setSignedIn(isSignedIn());
    setMenuOpen(false);
  }, [pathname]);

  const handleSignOut = () => {
    signOut();
    setSignedIn(false);
    setMenuOpen(false);
  };

  return (
    <nav className="nav">
      <div className="nav-bar">
        <Link to="/sessions" style={logoStyle}>
          Cloud Agents
        </Link>
        <button
          type="button"
          className="nav-toggle"
          aria-label="Toggle navigation menu"
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen(open => !open)}
        >
          <span className="nav-toggle-bars" aria-hidden="true" />
        </button>
      </div>
      <div className={`nav-links${menuOpen ? ' nav-links--open' : ''}`}>
        {NAV_ITEMS.map(item => (
          <Link key={item.to} to={item.to} style={{ ...linkStyle, color: pathname === item.to ? '#c9d1d9' : '#8b949e' }}>
            {item.label}
          </Link>
        ))}
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
          configured && (
            <button style={signInBtnStyle} onClick={() => beginLogin(clientId)} title="Sign in with GitHub (OAuth)">
              Sign in with GitHub
            </button>
          )
        )}
      </div>
    </nav>
  );
}

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
