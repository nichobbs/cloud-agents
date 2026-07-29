import { Link } from 'react-router-dom';
import { extractSessionPRs } from '../lib/sessionPRs';
import type { Message } from '../types';

interface SessionPRsPanelProps {
  sessionId: string;
  messages: Message[];
}

/// Pull requests referenced anywhere in this session's transcript — the ones
/// the agent opened or acted on — so they don't scroll away into collapsed
/// messages. Display-only (no GitHub API round trip); each row links to the
/// PR and deep-links back to the message it first appeared in. Renders
/// nothing when the transcript references no PRs.
export function SessionPRsPanel({ sessionId, messages }: SessionPRsPanelProps) {
  const prs = extractSessionPRs(messages);
  if (prs.length === 0) return null;

  return (
    <div style={panelStyle}>
      <div style={headerStyle}>PRs this session</div>
      {prs.map(pr => (
        <div key={pr.url} style={rowStyle}>
          <a href={pr.url} target="_blank" rel="noopener noreferrer" style={prLinkStyle} title={pr.url}>
            {pr.owner}/{pr.repo}#{pr.number}
          </a>
          <Link to={`/sessions/${sessionId}#message-${pr.messageId}`} style={sourceLinkStyle}>
            ↩ source
          </Link>
        </div>
      ))}
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const headerStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '10px',
  padding: '2px 0',
};

const prLinkStyle: React.CSSProperties = {
  fontSize: '12px',
  fontFamily: 'monospace',
  color: '#58a6ff',
  textDecoration: 'none',
  flex: 1,
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const sourceLinkStyle: React.CSSProperties = {
  fontSize: '10px',
  color: '#6e7681',
  textDecoration: 'none',
  flexShrink: 0,
};
