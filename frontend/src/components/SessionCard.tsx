import { Link } from 'react-router-dom';
import type { Session } from '../types';

interface SessionCardProps {
  session: Session;
}

function repoLabel(repoUrl: string): string {
  try {
    const parts = new URL(repoUrl).pathname.replace(/^\//, '').replace(/\.git$/, '');
    return parts || repoUrl;
  } catch {
    return repoUrl;
  }
}

function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  // Sessions hydrated from the server have no createdAt — render nothing
  // rather than "NaNd ago".
  if (!Number.isFinite(diff)) return '';
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

export function SessionCard({ session }: SessionCardProps) {
  return (
    <Link to={`/sessions/${session.sessionId}`} style={{ textDecoration: 'none' }}>
      <div style={cardStyle}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <span style={{ fontWeight: 600, color: '#58a6ff', fontSize: '14px' }}>
            {repoLabel(session.repoUrl)}
          </span>
          <span style={{ fontSize: '12px', color: '#484f58' }}>{timeAgo(session.createdAt)}</span>
        </div>
        <div style={{ marginTop: '6px', fontSize: '12px', color: '#8b949e' }}>
          branch: <code style={{ color: '#79c0ff' }}>{session.branch}</code>
        </div>
        <div style={{ marginTop: '4px', fontSize: '11px', color: '#484f58', fontFamily: 'monospace' }}>
          {session.sessionId}
        </div>
      </div>
    </Link>
  );
}

const cardStyle: React.CSSProperties = {
  padding: '14px 16px',
  border: '1px solid #30363d',
  borderRadius: '6px',
  background: '#161b22',
  cursor: 'pointer',
  transition: 'border-color 0.15s',
};
