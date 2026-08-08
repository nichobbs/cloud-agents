import { Link } from 'react-router-dom';
import { ATTENTION_META, sessionAttention } from '../lib/attention';
import { getHarness } from '../lib/harnesses';
import { formatFullTimestamp, timeAgo } from '../lib/time';
import type { Session } from '../types';

interface SessionCardProps {
  session: Session;
  /** Slimmer row for use inside the group tree (tighter padding, no id line). */
  compact?: boolean;
}

function repoLabel(repoUrl: string): string {
  try {
    const parts = new URL(repoUrl).pathname.replace(/^\//, '').replace(/\.git$/, '');
    return parts || repoUrl;
  } catch {
    return repoUrl;
  }
}

export function SessionCard({ session, compact }: SessionCardProps) {
  const created = timeAgo(session.createdAt);
  const lastActive = timeAgo(session.lastMessageAt);
  const status = session.status ?? '';
  const attention = sessionAttention(session);
  const attentionMeta = ATTENTION_META[attention];

  return (
    <Link to={`/sessions/${session.sessionId}`} style={{ textDecoration: 'none' }}>
      <div style={compact ? compactCardStyle : cardStyle}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: '8px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', minWidth: 0 }}>
            <span
              className={attention === 'working' ? 'attention-dot attention-dot--working' : 'attention-dot'}
              style={{ ...statusDotStyle, background: attentionMeta.color }}
              title={`Attention: ${attentionMeta.label}`}
            />
            <span style={{ fontWeight: 600, color: '#58a6ff', fontSize: '14px' }}>
              {repoLabel(session.repoUrl)}
            </span>
            {status === 'RUNNING' && <span style={runningBadgeStyle}>running</span>}
          </div>
          <span
            style={{ fontSize: '12px', color: '#484f58', flexShrink: 0 }}
            title={formatFullTimestamp(session.createdAt)}
          >
            {created ? `created ${created}` : ''}
          </span>
        </div>
        <div style={{ marginTop: '6px', fontSize: '12px', color: '#8b949e', display: 'flex', gap: '10px', flexWrap: 'wrap' }}>
          <span>
            branch: <code style={{ color: '#79c0ff' }}>{session.branch}</code>
          </span>
          <span style={harnessBadgeStyle}>{getHarness(session.harness ?? 'claude').label}</span>
          {session.model && <code style={{ color: '#6e7681', fontSize: '11px' }}>{session.model}</code>}
          {lastActive && (
            <span title={formatFullTimestamp(session.lastMessageAt)} style={{ color: '#6e7681' }}>
              active {lastActive}
            </span>
          )}
        </div>
        {!compact && (
          <div style={{ marginTop: '4px', fontSize: '11px', color: '#484f58', fontFamily: 'monospace' }}>
            {session.sessionId}
          </div>
        )}
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

const compactCardStyle: React.CSSProperties = {
  ...cardStyle,
  padding: '10px 12px',
};

const statusDotStyle: React.CSSProperties = {
  width: '8px',
  height: '8px',
  borderRadius: '50%',
  flexShrink: 0,
  display: 'inline-block',
};

const runningBadgeStyle: React.CSSProperties = {
  fontSize: '10px',
  fontWeight: 600,
  color: '#d29922',
  border: '1px solid #d29922',
  borderRadius: '999px',
  padding: '1px 7px',
  textTransform: 'uppercase',
  letterSpacing: '0.03em',
};

const harnessBadgeStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  background: '#21262d',
  border: '1px solid #30363d',
  borderRadius: '4px',
  padding: '0 6px',
};
