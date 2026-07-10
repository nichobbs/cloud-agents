import { Link, useLocation } from 'react-router-dom';

export function Nav() {
  const { pathname } = useLocation();
  const isNew = pathname === '/sessions/new';

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
          to="/prompts"
          style={{ ...linkStyle, color: pathname === '/prompts' ? '#c9d1d9' : '#8b949e' }}
        >
          Prompts
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
