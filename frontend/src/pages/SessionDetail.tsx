import { useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { Terminal } from '../components/Terminal';
import { useSessions } from '../context/SessionsContext';
import { useStreamMessage } from '../hooks/useStreamMessage';
import { api } from '../lib/api';

export function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const { getSession, removeSession } = useSessions();
  const navigate = useNavigate();
  const session = getSession(id ?? '');
  const { output, isStreaming, send } = useStreamMessage(id ?? '');
  const [input, setInput] = useState('');
  const [deleting, setDeleting] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  if (!session) {
    return (
      <div style={{ padding: '32px 24px', color: '#8b949e', textAlign: 'center' }}>
        Session not found.{' '}
        <button style={linkBtnStyle} onClick={() => navigate('/sessions')}>
          Back to sessions
        </button>
      </div>
    );
  }

  const repoName = (() => {
    try {
      return new URL(session.repoUrl).pathname.replace(/^\//, '').replace(/\.git$/, '');
    } catch {
      return session.repoUrl;
    }
  })();

  const handleSend = async () => {
    const text = input.trim();
    if (!text || isStreaming) return;
    setInput('');
    await send(text);
    textareaRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void handleSend();
    }
  };

  const handleDelete = async () => {
    if (!confirm(`Delete session ${session.sessionId.slice(0, 8)}…?`)) return;
    setDeleting(true);
    try {
      await api.deleteSession(session.sessionId);
    } catch {
      // server-side errors are best-effort; remove from local list regardless
    }
    removeSession(session.sessionId);
    navigate('/sessions');
  };

  return (
    <div style={pageStyle}>
      <div style={headerStyle}>
        <div>
          <div style={repoNameStyle}>{repoName}</div>
          <div style={metaStyle}>
            branch: <code style={{ color: '#79c0ff' }}>{session.branch}</code>
            <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
            <span style={{ fontFamily: 'monospace', fontSize: '11px' }}>
              {session.sessionId}
            </span>
          </div>
        </div>
        <button
          style={deleteBtnStyle}
          onClick={() => { void handleDelete(); }}
          disabled={deleting}
        >
          {deleting ? 'Deleting…' : 'Delete session'}
        </button>
      </div>

      <Terminal output={output} isStreaming={isStreaming} />

      <div style={inputRowStyle}>
        <textarea
          ref={textareaRef}
          style={textareaStyle}
          rows={3}
          placeholder="Send a message… (Enter to send, Shift+Enter for newline)"
          value={input}
          onChange={e => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          disabled={isStreaming}
        />
        <button
          style={{
            ...sendBtnStyle,
            opacity: isStreaming || !input.trim() ? 0.5 : 1,
            cursor: isStreaming || !input.trim() ? 'not-allowed' : 'pointer',
          }}
          onClick={() => { void handleSend(); }}
          disabled={isStreaming || !input.trim()}
        >
          {isStreaming ? 'Running…' : 'Send'}
        </button>
      </div>
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '900px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '16px',
  minHeight: 'calc(100vh - 57px)',
};

const headerStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'flex-start',
};

const repoNameStyle: React.CSSProperties = {
  fontSize: '16px',
  fontWeight: 600,
  color: '#c9d1d9',
  marginBottom: '4px',
};

const metaStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
};

const deleteBtnStyle: React.CSSProperties = {
  padding: '5px 12px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #f85149',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
  flexShrink: 0,
};

const inputRowStyle: React.CSSProperties = {
  display: 'flex',
  gap: '10px',
  alignItems: 'flex-end',
};

const textareaStyle: React.CSSProperties = {
  flex: 1,
  padding: '10px 12px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  fontFamily: 'inherit',
  resize: 'vertical',
  outline: 'none',
  boxSizing: 'border-box',
};

const sendBtnStyle: React.CSSProperties = {
  padding: '10px 20px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '14px',
  fontWeight: 500,
  flexShrink: 0,
  alignSelf: 'flex-end',
};

const linkBtnStyle: React.CSSProperties = {
  background: 'none',
  border: 'none',
  color: '#58a6ff',
  cursor: 'pointer',
  fontSize: 'inherit',
  padding: 0,
  textDecoration: 'underline',
};
