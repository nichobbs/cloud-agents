import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import type { Prompt } from '../types';

/// The prompt library: list, create, edit and delete saved prompts.
export function Prompts() {
  const [prompts, setPrompts] = useState<Prompt[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [body, setBody] = useState('');
  const [saving, setSaving] = useState(false);

  const reload = async () => {
    try {
      setPrompts(await api.getPrompts());
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load prompts');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const startEdit = (p: Prompt) => {
    setEditingId(p.id);
    setName(p.name);
    setBody(p.body);
  };

  const clearForm = () => {
    setEditingId(null);
    setName('');
    setBody('');
  };

  const save = async () => {
    if (!name.trim() || !body.trim() || saving) return;
    setSaving(true);
    setError('');
    try {
      if (editingId) {
        await api.updatePrompt(editingId, name.trim(), body);
      } else {
        await api.addPrompt(name.trim(), body);
      }
      clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save prompt');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (p: Prompt) => {
    if (!confirm(`Delete prompt "${p.name}"?`)) return;
    setError('');
    try {
      await api.deletePrompt(p.id);
      if (editingId === p.id) clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete prompt');
    }
  };

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Prompt library</h2>

      <div style={formStyle}>
        <input
          style={nameInputStyle}
          placeholder="Prompt name"
          value={name}
          onChange={e => setName(e.target.value)}
          maxLength={200}
        />
        <textarea
          style={bodyInputStyle}
          rows={5}
          placeholder="Prompt text…"
          value={body}
          onChange={e => setBody(e.target.value)}
        />
        <div style={{ display: 'flex', gap: '8px' }}>
          <button
            style={{ ...saveBtnStyle, opacity: name.trim() && body.trim() && !saving ? 1 : 0.5 }}
            onClick={() => { void save(); }}
            disabled={!name.trim() || !body.trim() || saving}
          >
            {saving ? 'Saving…' : editingId ? 'Update prompt' : 'Save prompt'}
          </button>
          {editingId && (
            <button style={cancelBtnStyle} onClick={clearForm}>
              Cancel edit
            </button>
          )}
        </div>
      </div>

      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && prompts.length === 0 && (
        <div style={mutedStyle}>No saved prompts yet — save one above, or from a session composer.</div>
      )}

      {prompts.map(p => (
        <div key={p.id} style={cardStyle}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div style={promptNameStyle}>{p.name}</div>
            <div style={{ display: 'flex', gap: '8px', flexShrink: 0 }}>
              <span style={useCountStyle} title="Times used">
                ×{p.useCount}
              </span>
              <button style={smallBtnStyle} onClick={() => startEdit(p)} aria-label={`Edit ${p.name}`}>
                Edit
              </button>
              <button
                style={{ ...smallBtnStyle, color: '#f85149', borderColor: '#f85149' }}
                onClick={() => { void remove(p); }}
                aria-label={`Delete ${p.name}`}
              >
                Delete
              </button>
            </div>
          </div>
          <pre style={promptBodyStyle}>{p.body}</pre>
        </div>
      ))}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '900px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '14px',
};

const titleStyle: React.CSSProperties = {
  fontSize: '18px',
  color: '#c9d1d9',
  margin: 0,
};

const formStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '14px',
};

const nameInputStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  outline: 'none',
};

const bodyInputStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  fontFamily: 'monospace',
  resize: 'vertical',
  outline: 'none',
};

const saveBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const cancelBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const cardStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
};

const promptNameStyle: React.CSSProperties = {
  fontWeight: 600,
  fontSize: '14px',
  color: '#58a6ff',
};

const useCountStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
  alignSelf: 'center',
};

const smallBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const promptBodyStyle: React.CSSProperties = {
  margin: 0,
  fontSize: '12px',
  color: '#8b949e',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
  maxHeight: '160px',
  overflowY: 'auto',
};

const errStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#f85149',
};

const mutedStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#6e7681',
  textAlign: 'center',
  padding: '16px',
};
