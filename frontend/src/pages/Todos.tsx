import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import { api } from '../lib/api';
import type { Todo } from '../types';

/// A session's todo / bookmark list. Items captured from a specific agent
/// response link back to it via `#message-<id>` so deferred work isn't lost.
export function Todos() {
  const { id } = useParams<{ id: string }>();
  const sessionId = id ?? '';
  const { getSession } = useSessions();
  const session = getSession(sessionId);
  const navigate = useNavigate();

  const [todos, setTodos] = useState<Todo[]>([]);
  const [draft, setDraft] = useState('');
  const [loading, setLoading] = useState(true);

  const reload = async () => {
    try {
      setTodos(await api.getTodos(sessionId));
    } catch {
      setTodos([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  const add = async () => {
    const note = draft.trim();
    if (!note) return;
    setDraft('');
    try {
      await api.addTodo(sessionId, '', note);
      await reload();
    } catch {
      /* ignore */
    }
  };

  const toggle = async (todo: Todo) => {
    // optimistic
    setTodos(prev => prev.map(t => (t.id === todo.id ? { ...t, done: t.done === '1' ? '0' : '1' } : t)));
    try {
      await api.toggleTodo(todo.id);
    } catch {
      void reload();
    }
  };

  const remove = async (todo: Todo) => {
    setTodos(prev => prev.filter(t => t.id !== todo.id));
    try {
      await api.deleteTodo(todo.id);
    } catch {
      void reload();
    }
  };

  return (
    <div style={pageStyle}>
      <div style={headerStyle}>
        <div>
          <div style={titleStyle}>Todos &amp; bookmarks</div>
          <div style={metaStyle}>
            {session ? (
              <Link to={`/sessions/${sessionId}`} style={{ color: '#58a6ff' }}>
                ← back to session
              </Link>
            ) : (
              <button style={linkBtnStyle} onClick={() => navigate('/sessions')}>
                ← back to sessions
              </button>
            )}
          </div>
        </div>
      </div>

      <div style={addRow}>
        <input
          style={inputStyle}
          placeholder="Add a todo…"
          value={draft}
          onChange={e => setDraft(e.target.value)}
          onKeyDown={e => {
            if (e.key === 'Enter') {
              e.preventDefault();
              void add();
            }
          }}
        />
        <button
          style={{ ...addBtnStyle, opacity: draft.trim() ? 1 : 0.5 }}
          onClick={() => { void add(); }}
          disabled={!draft.trim()}
        >
          Add
        </button>
      </div>

      {loading ? (
        <div style={emptyStyle}>Loading…</div>
      ) : todos.length === 0 ? (
        <div style={emptyStyle}>
          No todos yet. Bookmark an agent response, or add one above.
        </div>
      ) : (
        <div style={listStyle}>
          {todos.map(todo => (
            <div key={todo.id} style={itemStyle}>
              <input
                type="checkbox"
                checked={todo.done === '1'}
                onChange={() => { void toggle(todo); }}
                style={{ marginTop: '3px', cursor: 'pointer' }}
              />
              <div style={{ flex: 1 }}>
                <div
                  style={{
                    ...noteStyle,
                    textDecoration: todo.done === '1' ? 'line-through' : 'none',
                    color: todo.done === '1' ? '#6e7681' : '#c9d1d9',
                  }}
                >
                  {todo.note}
                </div>
                {todo.messageId ? (
                  <Link to={`/sessions/${sessionId}#message-${todo.messageId}`} style={sourceLink}>
                    ↩ jump to source message
                  </Link>
                ) : (
                  <span style={{ fontSize: '11px', color: '#6e7681' }}>standalone</span>
                )}
              </div>
              <button style={delBtn} onClick={() => { void remove(todo); }} title="Delete">
                ✕
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '760px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '16px',
};

const headerStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'flex-start',
};

const titleStyle: React.CSSProperties = {
  fontSize: '18px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const metaStyle: React.CSSProperties = {
  fontSize: '12px',
  marginTop: '4px',
};

const addRow: React.CSSProperties = {
  display: 'flex',
  gap: '8px',
};

const inputStyle: React.CSSProperties = {
  flex: 1,
  padding: '9px 12px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  outline: 'none',
};

const addBtnStyle: React.CSSProperties = {
  padding: '9px 18px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '14px',
  fontWeight: 500,
  cursor: 'pointer',
};

const listStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
};

const itemStyle: React.CSSProperties = {
  display: 'flex',
  gap: '10px',
  alignItems: 'flex-start',
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '8px',
  padding: '10px 12px',
};

const noteStyle: React.CSSProperties = {
  fontSize: '14px',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};

const sourceLink: React.CSSProperties = {
  fontSize: '11px',
  color: '#58a6ff',
  textDecoration: 'none',
  display: 'inline-block',
  marginTop: '4px',
};

const delBtn: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#6e7681',
  cursor: 'pointer',
  fontSize: '14px',
  flexShrink: 0,
};

const emptyStyle: React.CSSProperties = {
  fontSize: '14px',
  color: '#8b949e',
  textAlign: 'center',
  padding: '24px',
};

const linkBtnStyle: React.CSSProperties = {
  background: 'none',
  border: 'none',
  color: '#58a6ff',
  cursor: 'pointer',
  fontSize: 'inherit',
  padding: 0,
};
