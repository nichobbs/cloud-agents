import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import { parseAgentPlan, type PlanItem } from '../lib/agentPlan';
import type { Todo } from '../types';

interface TodoPanelProps {
  sessionId: string;
  /** Content of the latest agent message, for the parsed-plan fallback. */
  latestAgentContent: string;
  /** True while a run is streaming — the panel polls faster to show live status. */
  isStreaming: boolean;
  /**
   * Bumped by useStreamMessage on every `todo_update` SSE frame; a change
   * triggers an immediate reload, so agent-driven todo changes appear
   * push-style. Polling remains the fallback (reattached runs carry no SSE).
   */
  todoUpdates?: number;
}

/** Effective three-state status, tolerating rows from before the status column. */
export function effectiveStatus(t: Todo): 'pending' | 'in_progress' | 'done' {
  if (t.status === 'in_progress') return 'in_progress';
  if (t.status === 'done' || (!t.status && t.done === '1')) return 'done';
  return 'pending';
}

const NEXT_STATUS: Record<string, 'pending' | 'in_progress' | 'done'> = {
  pending: 'in_progress',
  in_progress: 'done',
  done: 'pending',
};

/// The session's todo list in the right column: database-backed todos the
/// agent maintains via the add_todo/update_todo MCP tools (and the human via
/// the panel/todo page), plus a read-only plan parsed from the latest agent
/// message for harnesses that can't call our tools (see lib/agentPlan.ts).
export function TodoPanel({ sessionId, latestAgentContent, isStreaming, todoUpdates }: TodoPanelProps) {
  const [todos, setTodos] = useState<Todo[]>([]);
  const [draft, setDraft] = useState('');
  const [adding, setAdding] = useState(false);
  const sessionRef = useRef(sessionId);
  useEffect(() => {
    sessionRef.current = sessionId;
  }, [sessionId]);

  const reload = useCallback(async () => {
    const forSession = sessionId;
    try {
      const ts = await api.getTodos(forSession);
      if (sessionRef.current === forSession) setTodos(ts);
    } catch {
      /* best effort — leave the current list */
    }
  }, [sessionId]);

  useEffect(() => {
    setTodos([]);
    void reload();
    // Poll faster while a run is live so agent-driven status changes show up
    // as they happen; slower when idle. The todo_update SSE signal below
    // makes changes on a locally-sent run appear instantly; this poll is the
    // fallback for reattached runs and other tabs.
    const interval = setInterval(() => { void reload(); }, isStreaming ? 4000 : 15000);
    return () => clearInterval(interval);
  }, [reload, isStreaming]);

  // Push-style refresh: a todo_update SSE frame arrived on the live stream.
  useEffect(() => {
    if (todoUpdates !== undefined && todoUpdates > 0) void reload();
  }, [todoUpdates, reload]);

  const add = async () => {
    const note = draft.trim();
    if (!note || adding) return;
    setAdding(true);
    setDraft('');
    try {
      await api.addTodo(sessionId, '', note);
      await reload();
    } catch {
      setDraft(note); // don't lose the text on failure
    } finally {
      setAdding(false);
    }
  };

  const cycle = async (todo: Todo) => {
    const next = NEXT_STATUS[effectiveStatus(todo)] ?? 'pending';
    // optimistic
    setTodos(prev => prev.map(t => (t.id === todo.id ? { ...t, status: next, done: next === 'done' ? '1' : '0' } : t)));
    try {
      await api.setTodoStatus(todo.id, next);
    } catch {
      // Older backend without the status route — fall back to toggle for the
      // pending<->done pair, then resync.
      try {
        if (next === 'done' || effectiveStatus(todo) === 'done') await api.toggleTodo(todo.id);
      } catch { /* give up quietly */ }
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

  const plan: PlanItem[] = parseAgentPlan(latestAgentContent);
  const doneCount = todos.filter(t => effectiveStatus(t) === 'done').length;

  return (
    <div style={panelStyle}>
      <div style={headerRowStyle}>
        <span style={headerStyle}>Todos</span>
        <span style={countStyle}>
          {todos.length > 0 ? `${doneCount}/${todos.length} done` : ''}
        </span>
        <Link to={`/sessions/${sessionId}/todos`} style={allLinkStyle}>
          all ↗
        </Link>
      </div>

      {todos.length === 0 && plan.length === 0 && (
        <div style={emptyStyle}>No todos yet — the agent's plan will appear here.</div>
      )}

      {todos.map(todo => {
        const status = effectiveStatus(todo);
        return (
          <div key={todo.id} style={itemRowStyle}>
            <button
              style={{ ...statusChipStyle, ...statusChipColors[status] }}
              onClick={() => { void cycle(todo); }}
              title={`Status: ${status.replace('_', ' ')} — click to change`}
            >
              {statusGlyph[status]}
            </button>
            <span
              style={{
                ...noteStyle,
                textDecoration: status === 'done' ? 'line-through' : 'none',
                color: status === 'done' ? '#6e7681' : status === 'in_progress' ? '#e3b341' : '#c9d1d9',
              }}
              title={todo.note}
            >
              {todo.note}
            </span>
            <button style={delBtnStyle} onClick={() => { void remove(todo); }} title="Delete">
              ✕
            </button>
          </div>
        );
      })}

      <div style={addRowStyle}>
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
      </div>

      {plan.length > 0 && (
        <div style={planWrapStyle}>
          <div style={planHeaderStyle} title="Parsed from the latest agent response — read-only">
            Agent plan (from last response)
          </div>
          {plan.map((p, i) => (
            <div key={i} style={planRowStyle}>
              <span style={{ ...planGlyphStyle, color: planColors[p.state] }}>{statusGlyph[p.state]}</span>
              <span
                style={{
                  ...planTextStyle,
                  textDecoration: p.state === 'done' ? 'line-through' : 'none',
                  color: p.state === 'done' ? '#6e7681' : p.state === 'in_progress' ? '#e3b341' : '#8b949e',
                }}
              >
                {p.text}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

const statusGlyph: Record<string, string> = {
  pending: '○',
  in_progress: '◐',
  done: '●',
};

const statusChipColors: Record<string, React.CSSProperties> = {
  pending: { color: '#8b949e', borderColor: '#30363d' },
  in_progress: { color: '#e3b341', borderColor: '#e3b341' },
  done: { color: '#3fb950', borderColor: '#3fb950' },
};

const planColors: Record<string, string> = {
  pending: '#8b949e',
  in_progress: '#e3b341',
  done: '#3fb950',
};

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const headerRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
};

const headerStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const countStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
  flex: 1,
};

const allLinkStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#58a6ff',
  textDecoration: 'none',
};

const emptyStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
};

const itemRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  gap: '8px',
  padding: '2px 0',
};

const statusChipStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '999px',
  fontSize: '11px',
  lineHeight: '16px',
  width: '20px',
  height: '20px',
  padding: 0,
  cursor: 'pointer',
  flexShrink: 0,
};

const noteStyle: React.CSSProperties = {
  flex: 1,
  fontSize: '12px',
  wordBreak: 'break-word',
};

const delBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#6e7681',
  cursor: 'pointer',
  fontSize: '11px',
  flexShrink: 0,
  padding: '0 2px',
};

const addRowStyle: React.CSSProperties = {
  marginTop: '4px',
};

const inputStyle: React.CSSProperties = {
  width: '100%',
  boxSizing: 'border-box',
  padding: '5px 8px',
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '12px',
  outline: 'none',
};

const planWrapStyle: React.CSSProperties = {
  marginTop: '8px',
  paddingTop: '8px',
  borderTop: '1px dashed #21262d',
  display: 'flex',
  flexDirection: 'column',
  gap: '3px',
};

const planHeaderStyle: React.CSSProperties = {
  fontSize: '10px',
  color: '#6e7681',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
  marginBottom: '2px',
};

const planRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  gap: '6px',
};

const planGlyphStyle: React.CSSProperties = {
  fontSize: '11px',
  flexShrink: 0,
  lineHeight: '16px',
};

const planTextStyle: React.CSSProperties = {
  fontSize: '12px',
  wordBreak: 'break-word',
};
