import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import type { Comment } from '../types';

interface CommentThreadProps {
  messageId: string;
  sessionId: string;
  onCountChange?: (count: number) => void;
}

/// Comments anchored to a single message: lists existing comments and lets the
/// user add a new one.
export function CommentThread({ messageId, sessionId, onCountChange }: CommentThreadProps) {
  const [comments, setComments] = useState<Comment[]>([]);
  const [draft, setDraft] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    api
      .getComments(messageId)
      .then(cs => {
        if (active) {
          setComments(cs);
          onCountChange?.(cs.length);
        }
      })
      .catch(() => {
        /* empty / unavailable thread is fine */
      });
    return () => {
      active = false;
    };
    // onCountChange intentionally omitted to avoid refetch loops
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [messageId]);

  const submit = async () => {
    const body = draft.trim();
    if (!body || saving) return;
    setSaving(true);
    setError(null);
    try {
      const created = await api.addComment(messageId, sessionId, body);
      setComments(prev => {
        const next = [...prev, created];
        onCountChange?.(next.length);
        return next;
      });
      setDraft('');
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div style={wrapStyle}>
      {comments.map(c => (
        <div key={c.id} style={commentStyle}>
          <div style={bodyStyle}>{c.body}</div>
          <div style={tsStyle}>{formatTime(c.createdAt)}</div>
        </div>
      ))}
      {comments.length === 0 && <div style={emptyStyle}>No comments yet.</div>}

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="Add a comment…"
          value={draft}
          onChange={e => setDraft(e.target.value)}
          onKeyDown={e => {
            if (e.key === 'Enter') {
              e.preventDefault();
              void submit();
            }
          }}
        />
        <button
          style={{ ...addBtnStyle, opacity: draft.trim() && !saving ? 1 : 0.5 }}
          onClick={() => { void submit(); }}
          disabled={!draft.trim() || saving}
        >
          {saving ? '…' : 'Comment'}
        </button>
      </div>
      {error && <div style={errStyle}>{error}</div>}
    </div>
  );
}

function formatTime(epochMillis: string): string {
  const n = Number(epochMillis);
  if (!Number.isFinite(n) || n <= 0) return '';
  return new Date(n).toLocaleString();
}

const wrapStyle: React.CSSProperties = {
  marginTop: '10px',
  paddingTop: '10px',
  borderTop: '1px solid #21262d',
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
};

const commentStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '6px',
  padding: '8px 10px',
};

const bodyStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#c9d1d9',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};

const tsStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
  marginTop: '4px',
};

const emptyStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
};

const formStyle: React.CSSProperties = {
  display: 'flex',
  gap: '8px',
};

const inputStyle: React.CSSProperties = {
  flex: 1,
  padding: '7px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
};

const addBtnStyle: React.CSSProperties = {
  padding: '7px 14px',
  background: '#21262d',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
  flexShrink: 0,
};

const errStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#f85149',
};
