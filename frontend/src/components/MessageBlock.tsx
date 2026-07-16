import { useState } from 'react';
import { api } from '../lib/api';
import { formatFullTimestamp, formatTimestamp } from '../lib/time';
import type { Message } from '../types';
import { AnsiContent } from './AnsiContent';
import { CommentThread } from './CommentThread';

interface MessageBlockProps {
  message: Message;
  highlighted?: boolean;
  onTodoAdded?: () => void;
}

/// One addressable transcript entry. Renders the message content and exposes
/// the two affordances that hang off it: commenting and bookmarking to the todo
/// list. The wrapper carries `id="message-<id>"` so todos can deep-link back.
export function MessageBlock({ message, highlighted, onTodoAdded }: MessageBlockProps) {
  const [showComments, setShowComments] = useState(false);
  const [commentCount, setCommentCount] = useState<number | null>(null);
  const [bookmarking, setBookmarking] = useState(false);

  const isUser = message.role === 'user';

  const bookmark = async () => {
    if (bookmarking) return;
    const note = prompt('Add to todo list — note for this item:', defaultNote(message));
    if (note === null) return; // cancelled
    const trimmed = note.trim();
    if (!trimmed) return;
    setBookmarking(true);
    try {
      await api.addTodo(message.sessionId, message.id, trimmed);
      onTodoAdded?.();
    } catch {
      /* surface nothing — best effort */
    } finally {
      setBookmarking(false);
    }
  };

  return (
    <div
      id={`message-${message.id}`}
      style={{
        ...blockStyle,
        borderColor: highlighted ? '#1f6feb' : '#30363d',
        boxShadow: highlighted ? '0 0 0 1px #1f6feb' : 'none',
      }}
    >
      <div style={headerRow}>
        <span style={{ ...roleBadge, ...(isUser ? userBadge : agentBadge) }}>
          {isUser ? 'you' : 'agent'}
        </span>
        <span style={tsStyle} title={formatFullTimestamp(message.createdAt)}>
          {formatTimestamp(message.createdAt)}
        </span>
        <div style={{ flex: 1 }} />
        <button
          style={actionBtn}
          onClick={() => setShowComments(v => !v)}
          title="Comment on this response"
        >
          💬 {commentCount !== null ? commentCount : 'Comment'}
        </button>
        <button
          style={actionBtn}
          onClick={() => { void bookmark(); }}
          disabled={bookmarking}
          title="Bookmark to the todo list"
        >
          🔖 {bookmarking ? '…' : 'Bookmark'}
        </button>
      </div>

      {isUser ? (
        <div style={userContent}>{message.content}</div>
      ) : (
        <AnsiContent text={message.content} />
      )}

      {showComments && (
        <CommentThread
          messageId={message.id}
          onCountChange={setCommentCount}
        />
      )}
    </div>
  );
}

function defaultNote(m: Message): string {
  const firstLine = m.content.split('\n')[0] ?? '';
  const clean = firstLine.replace(/\x1b\[[0-9;]*m/g, '').trim();
  return clean.slice(0, 80);
}

const blockStyle: React.CSSProperties = {
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '8px',
  padding: '12px 14px',
  scrollMarginTop: '70px',
};

const headerRow: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  marginBottom: '8px',
};

const roleBadge: React.CSSProperties = {
  fontSize: '11px',
  fontWeight: 600,
  padding: '2px 8px',
  borderRadius: '999px',
  textTransform: 'uppercase',
  letterSpacing: '0.03em',
};

const userBadge: React.CSSProperties = {
  background: 'rgba(56, 139, 253, 0.15)',
  color: '#79c0ff',
};

const agentBadge: React.CSSProperties = {
  background: 'rgba(63, 185, 80, 0.15)',
  color: '#56d364',
};

const tsStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
};

const actionBtn: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '12px',
  padding: '3px 8px',
  cursor: 'pointer',
};

const userContent: React.CSSProperties = {
  fontSize: '14px',
  color: '#c9d1d9',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};
