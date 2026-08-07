import { useMemo, useState } from 'react';
import type { ReactElement } from 'react';
import { api } from '../lib/api';
import { ATTENTION_META } from '../lib/attention';
import {
  buildSessionTree,
  countSessions,
  flattenGroups,
  pruneEmptyGroups,
  rollupAttention,
} from '../lib/sessionTree';
import type { GroupNode } from '../lib/sessionTree';
import type { Session, SessionGroup } from '../types';
import { SessionCard } from './SessionCard';

const COLLAPSED_KEY = 'cloud_agents_tree_collapsed';

function loadCollapsed(): Set<string> {
  try {
    return new Set(JSON.parse(localStorage.getItem(COLLAPSED_KEY) ?? '[]') as string[]);
  } catch {
    return new Set();
  }
}

interface GroupTreeProps {
  groups: SessionGroup[];
  /** Sessions already narrowed to the visible tab + active filters. */
  sessions: Session[];
  /** True while an attention/text filter is active — empty groups hide. */
  filtering: boolean;
  /** Re-fetch groups after any create/rename/delete/assign mutation. */
  onGroupsChanged: () => void;
  /** Reflect a session→group assignment into the sessions store. */
  onSessionAssigned: (sessionId: string, groupId: string) => void;
}

export function GroupTree({ groups, sessions, filtering, onGroupsChanged, onSessionAssigned }: GroupTreeProps) {
  const [collapsed, setCollapsed] = useState<Set<string>>(loadCollapsed);
  // '' = creating at root, a group id = creating a subgroup there, null = not creating.
  const [creatingIn, setCreatingIn] = useState<string | null>(null);
  const [newName, setNewName] = useState('');
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState('');
  const [error, setError] = useState('');

  const tree = useMemo(() => {
    const built = buildSessionTree(groups, sessions);
    return filtering ? pruneEmptyGroups(built) : built;
  }, [groups, sessions, filtering]);
  const flat = useMemo(() => flattenGroups(groups), [groups]);

  const toggleCollapsed = (id: string) => {
    setCollapsed(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...next]));
      return next;
    });
  };

  const submitCreate = async (parentId: string) => {
    const name = newName.trim();
    if (!name) return;
    try {
      await api.createGroup(name, parentId);
      setCreatingIn(null);
      setNewName('');
      setError('');
      onGroupsChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const submitRename = async (group: SessionGroup) => {
    const name = renameValue.trim();
    if (!name) return;
    try {
      await api.updateGroup(group.id, name, group.parentId);
      setRenamingId(null);
      setError('');
      onGroupsChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const handleDelete = async (group: SessionGroup) => {
    if (!window.confirm(`Delete group "${group.name}"? Subgroups and sessions move to its parent.`)) return;
    try {
      await api.deleteGroup(group.id);
      setError('');
      onGroupsChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const handleAssign = async (sessionId: string, groupId: string) => {
    try {
      await api.setSessionGroup(sessionId, groupId);
      setError('');
      onSessionAssigned(sessionId, groupId);
      onGroupsChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const createInput = (parentId: string): ReactElement => (
    <input
      aria-label="New group name"
      placeholder="Group name (Enter to create)"
      autoFocus
      value={newName}
      onChange={e => setNewName(e.target.value)}
      onKeyDown={e => {
        if (e.key === 'Enter') void submitCreate(parentId);
        if (e.key === 'Escape') {
          setCreatingIn(null);
          setNewName('');
        }
      }}
      style={inlineInputStyle}
    />
  );

  const renderSessionRow = (s: Session): ReactElement => (
    <div key={s.sessionId} style={sessionRowStyle}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <SessionCard session={s} compact />
      </div>
      <select
        aria-label={`Group for ${s.sessionId}`}
        value={s.groupId ?? ''}
        onChange={e => void handleAssign(s.sessionId, e.target.value)}
        style={assignSelectStyle}
      >
        <option value="">(none)</option>
        {flat.map(f => (
          <option key={f.group.id} value={f.group.id}>
            {`${'  '.repeat(f.depth)}${f.group.name}`}
          </option>
        ))}
      </select>
    </div>
  );

  const renderGroup = (node: GroupNode): ReactElement => {
    const g = node.group;
    const isCollapsed = collapsed.has(g.id);
    const rollup = rollupAttention(node);
    const meta = ATTENTION_META[rollup];
    const count = countSessions(node);
    return (
      <div key={g.id}>
        <div style={groupRowStyle}>
          <button
            aria-label={isCollapsed ? `Expand ${g.name}` : `Collapse ${g.name}`}
            onClick={() => toggleCollapsed(g.id)}
            style={disclosureBtnStyle}
          >
            {isCollapsed ? '▸' : '▾'}
          </button>
          <span
            className={rollup === 'working' ? 'attention-dot attention-dot--working' : 'attention-dot'}
            style={{ ...dotStyle, background: meta.color }}
            title={`Attention: ${meta.label}`}
          />
          {renamingId === g.id ? (
            <input
              aria-label={`New name for ${g.name}`}
              autoFocus
              value={renameValue}
              onChange={e => setRenameValue(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter') void submitRename(g);
                if (e.key === 'Escape') setRenamingId(null);
              }}
              style={inlineInputStyle}
            />
          ) : (
            <span style={groupNameStyle}>{g.name}</span>
          )}
          <span style={countBadgeStyle}>{count}</span>
          <button
            aria-label={`New subgroup in ${g.name}`}
            title="New subgroup"
            onClick={() => {
              setCreatingIn(g.id);
              setNewName('');
            }}
            style={iconBtnStyle}
          >
            +
          </button>
          <button
            aria-label={`Rename ${g.name}`}
            title="Rename group"
            onClick={() => {
              setRenamingId(g.id);
              setRenameValue(g.name);
            }}
            style={iconBtnStyle}
          >
            {'✎'}
          </button>
          <button
            aria-label={`Delete ${g.name}`}
            title="Delete group"
            onClick={() => void handleDelete(g)}
            style={iconBtnStyle}
          >
            {'🗑'}
          </button>
        </div>
        {creatingIn === g.id && <div style={indentStyle}>{createInput(g.id)}</div>}
        {!isCollapsed && (node.children.length > 0 || node.sessions.length > 0) && (
          <div style={{ ...indentStyle, display: 'flex', flexDirection: 'column', gap: '8px' }}>
            {node.children.map(c => renderGroup(c))}
            {node.sessions.map(s => renderSessionRow(s))}
          </div>
        )}
      </div>
    );
  };

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '10px' }}>
        <button
          onClick={() => {
            setCreatingIn('');
            setNewName('');
          }}
          style={newGroupBtnStyle}
        >
          New group
        </button>
        {creatingIn === '' && createInput('')}
      </div>
      {error && (
        <div role="alert" style={errorStyle}>
          {error}
        </div>
      )}
      <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
        {tree.roots.map(r => renderGroup(r))}
        {tree.ungrouped.map(s => renderSessionRow(s))}
      </div>
    </div>
  );
}

const groupRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  padding: '6px 8px',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '6px',
};

/* 12px per nesting level — narrow enough to stay usable on mobile. */
const indentStyle: React.CSSProperties = {
  paddingLeft: '12px',
  marginTop: '8px',
  marginBottom: '8px',
};

const sessionRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  gap: '8px',
  minWidth: 0,
};

const disclosureBtnStyle: React.CSSProperties = {
  background: 'none',
  border: 'none',
  color: '#8b949e',
  cursor: 'pointer',
  padding: '0 2px',
  fontSize: '12px',
  lineHeight: 1,
};

const dotStyle: React.CSSProperties = {
  width: '8px',
  height: '8px',
  borderRadius: '50%',
  flexShrink: 0,
  display: 'inline-block',
};

const groupNameStyle: React.CSSProperties = {
  fontSize: '13px',
  fontWeight: 600,
  color: '#c9d1d9',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
  flex: 1,
  minWidth: 0,
};

const countBadgeStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  background: '#21262d',
  border: '1px solid #30363d',
  borderRadius: '999px',
  padding: '0 7px',
  flexShrink: 0,
};

const iconBtnStyle: React.CSSProperties = {
  background: 'none',
  border: '1px solid #30363d',
  borderRadius: '4px',
  color: '#8b949e',
  cursor: 'pointer',
  padding: '1px 6px',
  fontSize: '12px',
  lineHeight: '16px',
  flexShrink: 0,
};

const newGroupBtnStyle: React.CSSProperties = {
  background: '#21262d',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  cursor: 'pointer',
  padding: '4px 12px',
  fontSize: '12px',
  fontWeight: 500,
};

const inlineInputStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  padding: '4px 8px',
  fontSize: '13px',
  outline: 'none',
  flex: 1,
  minWidth: 0,
};

const assignSelectStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '11px',
  padding: '2px 4px',
  maxWidth: '120px',
  alignSelf: 'center',
  flexShrink: 0,
};

const errorStyle: React.CSSProperties = {
  color: '#f85149',
  fontSize: '12px',
  margin: '0 0 10px',
};
