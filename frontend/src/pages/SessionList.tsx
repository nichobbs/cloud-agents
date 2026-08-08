import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import { GroupTree } from '../components/GroupTree';
import { SessionCard } from '../components/SessionCard';
import { api } from '../lib/api';
import { ATTENTION_META, sessionAttention } from '../lib/attention';
import { byAttention, byText } from '../lib/sessionTree';
import type { AttentionFilter } from '../lib/sessionTree';
import { getLogin, isSignedIn } from '../lib/auth';
import type { SessionGroup } from '../types';

const FILTER_PARAM_VALUES: readonly string[] = ['working', 'pending', 'viewed'];

const CHIP_DEFS: { key: AttentionFilter; label: string; color: string }[] = [
  { key: 'all', label: 'All', color: '#58a6ff' },
  { key: 'working', label: ATTENTION_META.working.label, color: ATTENTION_META.working.color },
  { key: 'pending', label: ATTENTION_META.pending.label, color: ATTENTION_META.pending.color },
  { key: 'viewed', label: ATTENTION_META.viewed.label, color: ATTENTION_META.viewed.color },
];

export function SessionList() {
  const { sessions, updateSession } = useSessions();
  const [tab, setTab] = useState<'active' | 'archived'>('active');
  const [searchParams, setSearchParams] = useSearchParams();
  const [text, setText] = useState('');
  // null = groups unavailable (older backend / load failed) → flat list, no
  // grouping UI. Attention chips keep working via the client-side fallback.
  const [groups, setGroups] = useState<SessionGroup[] | null>(null);

  const rawFilter = searchParams.get('filter') ?? '';
  const attentionFilter: AttentionFilter = FILTER_PARAM_VALUES.includes(rawFilter)
    ? (rawFilter as AttentionFilter)
    : 'all';

  const refreshGroups = useCallback(async () => {
    try {
      setGroups(await api.listGroups());
    } catch {
      setGroups(null);
    }
  }, []);

  useEffect(() => {
    void refreshGroups();
  }, [refreshGroups]);

  const setFilter = (f: AttentionFilter) => {
    const next = new URLSearchParams(searchParams);
    if (f === 'all') next.delete('filter');
    else next.set('filter', f);
    setSearchParams(next, { replace: true });
  };

  const tabSessions = sessions.filter(s =>
    tab === 'archived' ? s.isArchived === '1' : s.isArchived !== '1',
  );

  const counts = useMemo(() => {
    const c: Record<AttentionFilter, number> = {
      all: tabSessions.length,
      working: 0,
      pending: 0,
      viewed: 0,
    };
    for (const s of tabSessions) {
      const a = sessionAttention(s);
      if (a === 'working' || a === 'pending' || a === 'viewed') c[a] += 1;
    }
    return c;
  }, [tabSessions]);

  const filtering = attentionFilter !== 'all' || text.trim() !== '';
  const attentionPred = byAttention(attentionFilter);
  const textPred = byText(text);
  const visibleSessions = tabSessions.filter(s => attentionPred(s) && textPred(s));

  const showEmpty =
    visibleSessions.length === 0 && (groups === null || filtering || groups.length === 0);

  return (
    <div style={pageStyle}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '24px' }}>
        <div>
          <h1 style={h1Style}>Sessions</h1>
          <p style={{ color: '#8b949e', fontSize: '14px', margin: 0 }}>
            {sessions.length === 0
              ? 'No sessions yet.'
              : `${sessions.length} session${sessions.length === 1 ? '' : 's'}`}
          </p>
          {isSignedIn() && (
            <p style={{ color: '#8b949e', fontSize: '13px', margin: '4px 0 0' }}>
              Signed in as {getLogin()} — sessions and credentials are scoped to your account.
            </p>
          )}
        </div>
        <Link to="/sessions/new" style={primaryBtnStyle}>New session</Link>
      </div>

      <div style={tabContainerStyle}>
        <button
          onClick={() => setTab('active')}
          style={{
            ...tabButtonStyle,
            borderBottomColor: tab === 'active' ? '#58a6ff' : 'transparent',
            color: tab === 'active' ? '#f0f6fc' : '#8b949e',
          }}
        >
          Active ({sessions.filter(s => s.isArchived !== '1').length})
        </button>
        <button
          onClick={() => setTab('archived')}
          style={{
            ...tabButtonStyle,
            borderBottomColor: tab === 'archived' ? '#58a6ff' : 'transparent',
            color: tab === 'archived' ? '#f0f6fc' : '#8b949e',
          }}
        >
          Archived ({sessions.filter(s => s.isArchived === '1').length})
        </button>
      </div>

      <div style={chipsRowStyle}>
        {CHIP_DEFS.map(c => {
          const selected = attentionFilter === c.key;
          return (
            <button
              key={c.key}
              onClick={() => setFilter(c.key)}
              aria-pressed={selected}
              style={{
                ...chipStyle,
                borderColor: selected ? c.color : '#30363d',
                background: selected ? c.color : '#161b22',
                color: selected ? '#0d1117' : c.color,
              }}
            >
              {c.label} ({counts[c.key]})
            </button>
          );
        })}
      </div>

      <input
        aria-label="Filter sessions"
        placeholder="Filter sessions…"
        value={text}
        onChange={e => setText(e.target.value)}
        style={filterInputStyle}
      />

      {showEmpty ? (
        <div style={emptyStyle}>
          <p style={{ margin: '0 0 16px', color: '#8b949e' }}>
            {filtering
              ? 'No sessions match the current filters.'
              : tab === 'active'
                ? 'No active sessions.'
                : 'No archived sessions.'}
          </p>
          {tab === 'active' && !filtering && (
            <Link to="/sessions/new" style={primaryBtnStyle}>New session</Link>
          )}
        </div>
      ) : groups !== null ? (
        <GroupTree
          groups={groups}
          sessions={visibleSessions}
          filtering={filtering}
          onGroupsChanged={() => void refreshGroups()}
          onSessionAssigned={(sessionId, groupId) => updateSession(sessionId, { groupId })}
        />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {visibleSessions.map(s => (
            <SessionCard key={s.sessionId} session={s} />
          ))}
        </div>
      )}
    </div>
  );
}

const tabContainerStyle: React.CSSProperties = {
  display: 'flex',
  gap: '16px',
  borderBottom: '1px solid #30363d',
  marginBottom: '16px',
};

const tabButtonStyle: React.CSSProperties = {
  background: 'none',
  border: 'none',
  borderBottom: '2px solid transparent',
  padding: '8px 4px 12px',
  fontSize: '14px',
  fontWeight: 500,
  cursor: 'pointer',
  outline: 'none',
  transition: 'color 0.2s, border-color 0.2s',
};

/* Horizontally scrollable on narrow screens — chips never wrap. */
const chipsRowStyle: React.CSSProperties = {
  display: 'flex',
  gap: '8px',
  overflowX: 'auto',
  whiteSpace: 'nowrap',
  paddingBottom: '4px',
  marginBottom: '10px',
};

const chipStyle: React.CSSProperties = {
  border: '1px solid #30363d',
  borderRadius: '999px',
  padding: '4px 12px',
  fontSize: '12px',
  fontWeight: 600,
  cursor: 'pointer',
  whiteSpace: 'nowrap',
  flexShrink: 0,
  transition: 'background 0.15s, color 0.15s, border-color 0.15s',
};

const filterInputStyle: React.CSSProperties = {
  width: '100%',
  boxSizing: 'border-box',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  padding: '6px 10px',
  fontSize: '13px',
  marginBottom: '16px',
  outline: 'none',
};

const pageStyle: React.CSSProperties = {
  maxWidth: '720px',
  margin: '0 auto',
  padding: '32px 24px',
};

const h1Style: React.CSSProperties = {
  margin: '0 0 4px',
  fontSize: '20px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const emptyStyle: React.CSSProperties = {
  textAlign: 'center',
  padding: '48px 24px',
  border: '1px dashed #30363d',
  borderRadius: '6px',
};

const primaryBtnStyle: React.CSSProperties = {
  display: 'inline-block',
  padding: '8px 16px',
  background: '#1f6feb',
  color: '#fff',
  borderRadius: '6px',
  textDecoration: 'none',
  fontSize: '14px',
  fontWeight: 500,
};
