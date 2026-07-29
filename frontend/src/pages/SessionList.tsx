import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import { SessionCard } from '../components/SessionCard';
import { getLogin, isSignedIn } from '../lib/auth';

export function SessionList() {
  const { sessions } = useSessions();
  const [tab, setTab] = useState<'active' | 'archived'>('active');

  const filteredSessions = sessions.filter(s => {
    if (tab === 'archived') {
      return s.isArchived === '1';
    } else {
      return s.isArchived !== '1';
    }
  });

  return (
    <div style={pageStyle}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '24px' }}>
        <div>
          <h1 style={h1Style}>Sessions</h1>
          <p style={{ color: '#8b949e', fontSize: '14px', margin: 0 }}>
            {sessions.length === 0
              ? 'No sessions yet.'
              : `${sessions.length} session${sessions.length === 1 ? '' : 's'}`}
          </p>
          {isSignedIn() && (
            <p style={{ color: '#8b949e', fontSize: '13px', margin: '4px 0 0' }}>
              Signed in as {getLogin()} — sessions and credentials are scoped to your account.
            </p>
          )}
        </div>
        <Link to="/sessions/new" style={primaryBtnStyle}>New session</Link>
      </div>

      <div style={tabContainerStyle}>
        <button
          onClick={() => setTab('active')}
          style={{
            ...tabButtonStyle,
            borderBottomColor: tab === 'active' ? '#58a6ff' : 'transparent',
            color: tab === 'active' ? '#f0f6fc' : '#8b949e',
          }}
        >
          Active ({sessions.filter(s => s.isArchived !== '1').length})
        </button>
        <button
          onClick={() => setTab('archived')}
          style={{
            ...tabButtonStyle,
            borderBottomColor: tab === 'archived' ? '#58a6ff' : 'transparent',
            color: tab === 'archived' ? '#f0f6fc' : '#8b949e',
          }}
        >
          Archived ({sessions.filter(s => s.isArchived === '1').length})
        </button>
      </div>

      {filteredSessions.length === 0 ? (
        <div style={emptyStyle}>
          <p style={{ margin: '0 0 16px', color: '#8b949e' }}>
            {tab === 'active'
              ? 'No active sessions.'
              : 'No archived sessions.'}
          </p>
          {tab === 'active' && (
            <Link to="/sessions/new" style={primaryBtnStyle}>New session</Link>
          )}
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {filteredSessions.map(s => (
            <SessionCard key={s.sessionId} session={s} />
          ))}
        </div>
      )}
    </div>
  );
}

const tabContainerStyle: React.CSSProperties = {
  display: 'flex',
  gap: '16px',
  borderBottom: '1px solid #30363d',
  marginBottom: '20px',
};

const tabButtonStyle: React.CSSProperties = {
  background: 'none',
  border: 'none',
  borderBottom: '2px solid transparent',
  padding: '8px 4px 12px',
  fontSize: '14px',
  fontWeight: 500,
  cursor: 'pointer',
  outline: 'none',
  transition: 'color 0.2s, border-color 0.2s',
};

const pageStyle: React.CSSProperties = {
  maxWidth: '720px',
  margin: '0 auto',
  padding: '32px 24px',
};

const h1Style: React.CSSProperties = {
  margin: '0 0 4px',
  fontSize: '20px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const emptyStyle: React.CSSProperties = {
  textAlign: 'center',
  padding: '48px 24px',
  border: '1px dashed #30363d',
  borderRadius: '6px',
};

const primaryBtnStyle: React.CSSProperties = {
  display: 'inline-block',
  padding: '8px 16px',
  background: '#1f6feb',
  color: '#fff',
  borderRadius: '6px',
  textDecoration: 'none',
  fontSize: '14px',
  fontWeight: 500,
};
