import { Link } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import { SessionCard } from '../components/SessionCard';

export function SessionList() {
  const { sessions } = useSessions();

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
        </div>
      </div>

      {sessions.length === 0 ? (
        <div style={emptyStyle}>
          <p style={{ margin: '0 0 16px', color: '#8b949e' }}>
            Create a session to run Claude Code against a repository.
          </p>
          <Link to="/sessions/new" style={primaryBtnStyle}>New session</Link>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {sessions.map(s => (
            <SessionCard key={s.sessionId} session={s} />
          ))}
        </div>
      )}
    </div>
  );
}

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
