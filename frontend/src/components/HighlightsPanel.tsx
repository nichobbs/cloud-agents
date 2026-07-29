import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import type { Highlight } from '../types';

interface HighlightsPanelProps {
  sessionId: string;
  /** True while a run is streaming; a falling edge triggers a refresh scan. */
  isStreaming: boolean;
}

const KIND_META: Record<string, { label: string; color: string; icon: string }> = {
  discovery: { label: 'discovery', color: '#79c0ff', icon: '🔎' },
  issue: { label: 'issue', color: '#f0883e', icon: '🎫' },
  workaround: { label: 'workaround', color: '#e3b341', icon: '🩹' },
  revert: { label: 'revert', color: '#f85149', icon: '↩' },
  incomplete: { label: 'incomplete', color: '#f85149', icon: '⚠' },
  followup: { label: 'follow-up', color: '#8b949e', icon: '📌' },
};

/// Notable items the summarizer model extracted from agent responses —
/// discoveries, tickets opened/closed, workarounds, reverts, incomplete
/// work — so they don't stay buried in a long transcript. Issues get their
/// own section. Refresh runs automatically when a run finishes (the backend
/// scans only new agent messages) and can be triggered manually.
export function HighlightsPanel({ sessionId, isStreaming }: HighlightsPanelProps) {
  const [highlights, setHighlights] = useState<Highlight[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [disabled, setDisabled] = useState(false);
  const [error, setError] = useState('');
  const sessionRef = useRef(sessionId);
  useEffect(() => {
    sessionRef.current = sessionId;
  }, [sessionId]);

  const reload = useCallback(async () => {
    const forSession = sessionId;
    try {
      const hs = await api.getHighlights(forSession);
      if (sessionRef.current === forSession) setHighlights(hs);
    } catch {
      /* older backend — hide quietly */
    }
  }, [sessionId]);

  const refresh = useCallback(async () => {
    const forSession = sessionId;
    if (refreshing) return;
    setRefreshing(true);
    setError('');
    try {
      const result = await api.refreshHighlights(forSession);
      if (sessionRef.current !== forSession) return;
      if (result.status === 'disabled') {
        setDisabled(true);
        return;
      }
      setDisabled(false);
      if (result.status === 'error' && result.detail) {
        setError(result.detail);
      }
      await reload();
    } catch {
      /* older backend — hide quietly */
    } finally {
      if (sessionRef.current === forSession) setRefreshing(false);
    }
  }, [sessionId, refreshing, reload]);

  useEffect(() => {
    setHighlights([]);
    setDisabled(false);
    setError('');
    void reload();
  }, [sessionId, reload]);

  // Falling edge of isStreaming = a run just finished — scan its output.
  const prevStreamingRef = useRef(isStreaming);
  useEffect(() => {
    if (prevStreamingRef.current && !isStreaming) {
      void refresh();
    }
    prevStreamingRef.current = isStreaming;
  }, [isStreaming, refresh]);

  const issues = highlights.filter(h => h.kind === 'issue');
  const others = highlights.filter(h => h.kind !== 'issue');

  if (disabled && highlights.length === 0) {
    return null; // no summarizer configured and nothing stored — hide entirely
  }

  return (
    <div style={panelStyle}>
      <div style={headerRowStyle}>
        <span style={headerStyle}>Highlights</span>
        <span style={{ flex: 1 }} />
        <button
          style={refreshBtnStyle}
          onClick={() => { void refresh(); }}
          disabled={refreshing}
          title="Scan new agent responses for notable items (uses the configured summarizer model)"
        >
          {refreshing ? 'Scanning…' : '↻ Scan'}
        </button>
      </div>

      {error && <div style={errorStyle} title={error}>Summarizer error — will retry on next scan.</div>}

      {highlights.length === 0 && !refreshing && (
        <div style={emptyStyle}>
          Nothing surfaced yet. Discoveries, tickets, workarounds, reverts and
          incomplete work found in agent responses will appear here after each run.
        </div>
      )}

      {issues.length > 0 && (
        <div style={sectionStyle}>
          <div style={sectionHeaderStyle}>Issues this session</div>
          {issues.map(h => <HighlightRow key={h.id} h={h} sessionId={sessionId} />)}
        </div>
      )}

      {others.length > 0 && (
        <div style={sectionStyle}>
          {issues.length > 0 && <div style={sectionHeaderStyle}>Other</div>}
          {others.map(h => <HighlightRow key={h.id} h={h} sessionId={sessionId} />)}
        </div>
      )}
    </div>
  );
}

function HighlightRow({ h, sessionId }: { h: Highlight; sessionId: string }) {
  const meta = KIND_META[h.kind] ?? { label: h.kind, color: '#8b949e', icon: '•' };
  // One-click "add to todos" for followup-kind items: the summarizer spotted
  // suggested follow-up work — promote it onto the session's todo plan,
  // anchored to the message it came from. 'added' is per-mount only; the
  // todo list itself is the durable record.
  const [added, setAdded] = useState(false);
  const [adding, setAdding] = useState(false);
  const addAsTodo = async () => {
    if (adding || added) return;
    setAdding(true);
    try {
      const note = h.detail ? `${h.title} — ${h.detail}` : h.title;
      await api.addTodo(sessionId, h.messageId, note);
      setAdded(true);
    } catch {
      /* best effort — leave the button usable */
    } finally {
      setAdding(false);
    }
  };
  return (
    <div style={rowStyle}>
      <span style={{ ...kindChipStyle, color: meta.color, borderColor: meta.color }} title={meta.label}>
        {meta.icon} {meta.label}
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={titleStyle} title={h.title}>{h.title}</div>
        {h.detail && <div style={detailStyle}>{h.detail}</div>}
        <div style={rowActionsStyle}>
          {h.messageId && (
            <Link to={`/sessions/${sessionId}#message-${h.messageId}`} style={sourceLinkStyle}>
              ↩ source
            </Link>
          )}
          {h.kind === 'followup' && (
            <button
              style={{ ...addTodoBtnStyle, opacity: added ? 0.6 : 1 }}
              onClick={() => { void addAsTodo(); }}
              disabled={adding || added}
              title="Add this follow-up to the session's todo list"
            >
              {added ? '✓ added to todos' : adding ? 'adding…' : '+ add to todos'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
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

const refreshBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '11px',
  padding: '2px 8px',
  cursor: 'pointer',
};

const emptyStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
};

const errorStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#d29922',
};

const sectionStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const sectionHeaderStyle: React.CSSProperties = {
  fontSize: '10px',
  color: '#6e7681',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  gap: '8px',
  padding: '4px 0',
  borderTop: '1px solid #161b22',
};

const kindChipStyle: React.CSSProperties = {
  fontSize: '10px',
  border: '1px solid',
  borderRadius: '999px',
  padding: '1px 7px',
  whiteSpace: 'nowrap',
  flexShrink: 0,
  marginTop: '1px',
};

const titleStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#c9d1d9',
  wordBreak: 'break-word',
};

const detailStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  marginTop: '2px',
  wordBreak: 'break-word',
};

const sourceLinkStyle: React.CSSProperties = {
  fontSize: '10px',
  color: '#58a6ff',
  textDecoration: 'none',
  display: 'inline-block',
};

const rowActionsStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '10px',
  marginTop: '3px',
};

const addTodoBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '999px',
  color: '#8b949e',
  fontSize: '10px',
  padding: '1px 8px',
  cursor: 'pointer',
};
