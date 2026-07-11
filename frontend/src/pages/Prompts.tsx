import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import type { Prompt } from '../types';

/// The prompt library: list, create, edit and delete saved prompts.
type View = { kind: 'all' } | { kind: 'popular' } | { kind: 'tag'; tag: string };

/** Split a comma/space separated tag input into a clean, de-duplicated list. */
function parseTags(input: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of input.split(/[,\s]+/)) {
    const t = raw.trim();
    if (t && !seen.has(t)) {
      seen.add(t);
      out.push(t);
    }
  }
  return out;
}

export function Prompts() {
  const [prompts, setPrompts] = useState<Prompt[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [body, setBody] = useState('');
  const [tagsInput, setTagsInput] = useState('');
  const [saving, setSaving] = useState(false);
  const [view, setView] = useState<View>({ kind: 'all' });

  const load = async (v: View) => {
    setLoading(true);
    try {
      const list =
        v.kind === 'popular'
          ? await api.getPopularPrompts()
          : v.kind === 'tag'
            ? await api.getPromptsByTag(v.tag)
            : await api.getPrompts();
      setPrompts(list);
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load prompts');
    } finally {
      setLoading(false);
    }
  };

  const reload = async () => { await load(view); };

  useEffect(() => {
    void load(view);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view]);

  const startEdit = (p: Prompt) => {
    setEditingId(p.id);
    setName(p.name);
    setBody(p.body);
    setTagsInput(p.tags.join(', '));
  };

  const clearForm = () => {
    setEditingId(null);
    setName('');
    setBody('');
    setTagsInput('');
  };

  const save = async () => {
    if (!name.trim() || !body.trim() || saving) return;
    setSaving(true);
    setError('');
    const tags = parseTags(tagsInput);
    try {
      if (editingId) {
        await api.updatePrompt(editingId, name.trim(), body, tags);
      } else {
        await api.addPrompt(name.trim(), body, tags);
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

      <div style={filterBarStyle}>
        <button
          style={filterBtnStyle(view.kind === 'all')}
          onClick={() => setView({ kind: 'all' })}
        >
          All
        </button>
        <button
          style={filterBtnStyle(view.kind === 'popular')}
          onClick={() => setView({ kind: 'popular' })}
        >
          Most used
        </button>
        {view.kind === 'tag' && (
          <span style={activeTagStyle}>
            tag: {view.tag}
            <button style={clearTagBtnStyle} onClick={() => setView({ kind: 'all' })} aria-label="Clear tag filter">
              ×
            </button>
          </span>
        )}
      </div>

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
          placeholder="Prompt text… use {{name}} for variables to fill in at run time"
          value={body}
          onChange={e => setBody(e.target.value)}
        />
        <input
          style={nameInputStyle}
          placeholder="Tags (comma-separated, e.g. deploy, ci)"
          value={tagsInput}
          onChange={e => setTagsInput(e.target.value)}
          aria-label="Prompt tags"
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
          {p.tags.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
              {p.tags.map(t => (
                <button
                  key={t}
                  style={tagChipStyle}
                  onClick={() => setView({ kind: 'tag', tag: t })}
                  title={`Filter by "${t}"`}
                >
                  {t}
                </button>
              ))}
            </div>
          )}
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

const filterBarStyle: React.CSSProperties = { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' };

const filterBtnStyle = (on: boolean): React.CSSProperties => ({
  padding: '4px 12px',
  background: on ? '#1f6feb' : 'transparent',
  color: on ? '#fff' : '#8b949e',
  border: `1px solid ${on ? '#1f6feb' : '#30363d'}`,
  borderRadius: '14px',
  fontSize: '12px',
  cursor: 'pointer',
});

const activeTagStyle: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: '4px',
  fontSize: '12px',
  color: '#79c0ff',
  background: '#1f6feb22',
  border: '1px solid #1f6feb',
  borderRadius: '14px',
  padding: '3px 10px',
};

const clearTagBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#79c0ff',
  cursor: 'pointer',
  fontSize: '14px',
  lineHeight: 1,
  padding: 0,
};

const tagChipStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '10px',
  padding: '2px 8px',
  cursor: 'pointer',
};
