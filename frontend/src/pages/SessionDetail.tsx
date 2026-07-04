import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { MessageBlock } from '../components/MessageBlock';
import { Terminal } from '../components/Terminal';
import { useSessions } from '../context/SessionsContext';
import { useStreamMessage } from '../hooks/useStreamMessage';
import { getHarness } from '../lib/harnesses';
import { api } from '../lib/api';
import type { Message } from '../types';

export function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const sessionId = id ?? '';
  const { getSession, removeSession, updateSession } = useSessions();
  const navigate = useNavigate();
  const location = useLocation();
  const session = getSession(sessionId);
  const { output, isStreaming, error: sendError, send, reset } = useStreamMessage(sessionId);

  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [deleting, setDeleting] = useState(false);
  const [modelSwitching, setModelSwitching] = useState(false);
  const [modelError, setModelError] = useState('');
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Tracks which session this component instance is currently showing, so a
  // handleSend() call that outlives a navigation to a different session (a
  // send can take up to 30 minutes) can tell it's stale and bail out instead
  // of folding its result into the wrong session's view. SessionDetail isn't
  // remounted on navigation between sessions, only re-rendered with a new
  // `sessionId`, so a plain closure over `sessionId` inside handleSend isn't
  // enough on its own — this ref is what lets that closure check itself
  // against the *current* session after an awaited call returns.
  const currentSessionRef = useRef(sessionId);
  useEffect(() => {
    currentSessionRef.current = sessionId;
  }, [sessionId]);

  const highlightedId = location.hash.startsWith('#message-')
    ? location.hash.slice('#message-'.length)
    : null;

  // Single place that actually calls the transcript API and absorbs its
  // errors (transcript may be empty or unavailable; leave state as-is on
  // failure) — both call sites below just decide when to apply the result.
  const fetchMessages = useCallback(async (forSessionId: string): Promise<Message[] | null> => {
    try {
      return await api.getMessages(forSessionId);
    } catch {
      return null;
    }
  }, []);

  // Used for explicit, one-off refreshes (e.g. right after a successful
  // send) where there's no concurrent fetch to race against.
  const reload = useCallback(async () => {
    const fetched = await fetchMessages(sessionId);
    if (fetched) setMessages(fetched);
  }, [sessionId, fetchMessages]);

  useEffect(() => {
    // Guard against a slow fetch for a previous session resolving after
    // navigating to a new one and overwriting its transcript with stale data
    // — session switches change `sessionId` without remounting this
    // component, so a request in flight can outlive the session it was for.
    // Same pattern as CommentThread.tsx's `active` flag.
    let active = true;
    fetchMessages(sessionId).then(fetched => {
      if (active && fetched) setMessages(fetched);
    });
    return () => {
      active = false;
    };
  }, [sessionId, fetchMessages]);

  // Deep-link: scroll to the message referenced by the URL hash once loaded.
  useEffect(() => {
    if (!highlightedId || messages.length === 0) return;
    const el = document.getElementById(`message-${highlightedId}`);
    el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, [highlightedId, messages]);

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
    const forSession = sessionId;
    setInput('');
    const succeeded = await send(text);

    if (currentSessionRef.current !== forSession) {
      // The user navigated to a different session while this send was in
      // flight. useStreamMessage already keeps its own output/error state
      // from leaking across the switch; this guard does the same for the
      // continuation below, which would otherwise reload() the *current*
      // session's transcript with the *stale* session's messages, or steal
      // focus into a textarea the user isn't looking at anymore.
      return;
    }

    if (succeeded) {
      // Fold the completed run into the persisted transcript and clear the
      // live panel.
      await reload();
      reset();
    } else {
      // Restore the prompt so a failed send (network error, container
      // crash, backend 500) doesn't silently discard what the user typed —
      // and leave `output`/`error` populated so the failure is visible
      // instead of being wiped immediately.
      setInput(text);
    }
    textareaRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void handleSend();
    }
  };

  const handleModelChange = async (newModel: string) => {
    if (!session || modelSwitching || isStreaming) return;
    setModelSwitching(true);
    setModelError('');
    try {
      await api.updateSessionModel(session.sessionId, newModel);
      updateSession(session.sessionId, { model: newModel });
    } catch (err) {
      setModelError(err instanceof Error ? err.message : 'Failed to switch model');
    } finally {
      setModelSwitching(false);
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
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '4px' }}>
            <div style={repoNameStyle}>{repoName}</div>
            <span style={harnessBadgeStyle}>
              {getHarness(session.harness ?? 'claude').label}
            </span>
          </div>
          <div style={metaStyle}>
            branch: <code style={{ color: '#79c0ff' }}>{session.branch}</code>
            <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
            model:{' '}
            <select
              style={modelSelectStyle}
              value={session.model ?? ''}
              onChange={e => { void handleModelChange(e.target.value); }}
              disabled={modelSwitching || isStreaming}
              title="Switch model (takes effect on next message)"
            >
              {getHarness(session.harness ?? 'claude').models.map(m => (
                <option key={m.id} value={m.id}>{m.label}</option>
              ))}
            </select>
            <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
            <span style={{ fontFamily: 'monospace', fontSize: '11px' }}>
              {session.sessionId}
            </span>
          </div>
          {modelError && <div style={modelErrorStyle}>Model switch failed: {modelError}</div>}
        </div>
        <div style={{ display: 'flex', gap: '8px', flexShrink: 0 }}>
          <Link to={`/sessions/${sessionId}/todos`} style={todosBtnStyle}>
            Todos
          </Link>
          <button
            style={deleteBtnStyle}
            onClick={() => { void handleDelete(); }}
            disabled={deleting}
          >
            {deleting ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>

      <div style={transcriptStyle}>
        {messages.length === 0 && !isStreaming && !sendError && (
          <div style={emptyStyle}>
            No messages yet — send a prompt below to start the session.
          </div>
        )}
        {messages.map(m => (
          <MessageBlock
            key={m.id}
            message={m}
            highlighted={m.id === highlightedId}
            onTodoAdded={() => { /* todos live on their own page */ }}
          />
        ))}
        {(isStreaming || sendError) && (
          <div style={liveWrapStyle}>
            <div style={sendError ? liveErrorLabelStyle : liveLabelStyle}>
              {isStreaming ? 'running…' : 'failed'}
            </div>
            <Terminal output={output} isStreaming={isStreaming} />
          </div>
        )}
      </div>

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
};

const harnessBadgeStyle: React.CSSProperties = {
  fontSize: '11px',
  fontWeight: 500,
  color: '#8b949e',
  background: '#21262d',
  border: '1px solid #30363d',
  borderRadius: '4px',
  padding: '1px 6px',
  whiteSpace: 'nowrap',
};

const modelSelectStyle: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#79c0ff',
  fontSize: '12px',
  fontFamily: 'monospace',
  cursor: 'pointer',
  padding: 0,
  outline: 'none',
};

const modelErrorStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#f85149',
  marginTop: '4px',
};

const metaStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
};

const transcriptStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
  flex: 1,
};

const emptyStyle: React.CSSProperties = {
  color: '#6e7681',
  fontSize: '14px',
  textAlign: 'center',
  padding: '32px',
};

const liveWrapStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const liveLabelStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#56d364',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const liveErrorLabelStyle: React.CSSProperties = {
  ...liveLabelStyle,
  color: '#f85149',
};

const todosBtnStyle: React.CSSProperties = {
  padding: '5px 12px',
  background: '#21262d',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '13px',
  textDecoration: 'none',
};

const deleteBtnStyle: React.CSSProperties = {
  padding: '5px 12px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #f85149',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
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
