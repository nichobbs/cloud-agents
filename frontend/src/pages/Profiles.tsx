import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import type { Profile } from '../types';

/// Container profiles: a per-container policy bundling which harness runs, what
/// network access the container gets, and which credentials are injected
/// (least privilege). Attach a profile to a session on its detail page.
export function Profiles() {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [credNames, setCredNames] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [harness, setHarness] = useState('');
  const [networkPolicy, setNetworkPolicy] = useState('full');
  const [credentialMode, setCredentialMode] = useState('all');
  const [grants, setGrants] = useState<string[]>([]);

  const reload = async () => {
    try {
      const [ps, creds] = await Promise.all([api.getProfiles(), api.getCredentialNames()]);
      setProfiles(ps);
      setCredNames(creds.map(c => c.name));
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load profiles');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const clearForm = () => {
    setEditingId(null);
    setName('');
    setHarness('');
    setNetworkPolicy('full');
    setCredentialMode('all');
    setGrants([]);
  };

  const startEdit = (p: Profile) => {
    setEditingId(p.id);
    setName(p.name);
    setHarness(p.harness);
    setNetworkPolicy(p.networkPolicy);
    setCredentialMode(p.credentialMode);
    setGrants(p.credentials);
  };

  const toggleGrant = (grantName: string) => {
    setGrants(g => (g.includes(grantName) ? g.filter(x => x !== grantName) : [...g, grantName]));
  };

  const save = async () => {
    if (!name.trim() || saving) return;
    setSaving(true);
    setError('');
    const payload = {
      name: name.trim(),
      harness,
      networkPolicy,
      credentialMode,
      credentials: credentialMode === 'selected' ? grants : [],
    };
    try {
      if (editingId) {
        await api.updateProfile(editingId, payload);
      } else {
        await api.addProfile(payload);
      }
      clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save profile');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (p: Profile) => {
    if (!confirm(`Delete profile "${p.name}"? Sessions using it will fall back to no profile.`)) return;
    setError('');
    try {
      await api.deleteProfile(p.id);
      if (editingId === p.id) clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete profile');
    }
  };

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Profiles</h2>
      <p style={subtitleStyle}>
        A profile is a per-container policy: the harness it runs, the network access it gets, and the
        credentials it can see (least privilege). Attach a profile to a session on its detail page — a
        session with no profile injects all credentials and gets full network (the legacy default).
      </p>

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="Profile name (e.g. prod-deploy)"
          value={name}
          onChange={e => setName(e.target.value)}
          maxLength={200}
          aria-label="Profile name"
        />

        <div style={rowFieldsStyle}>
          <label style={fieldStyle}>
            <span style={labelStyle}>Harness</span>
            <select style={selectStyle} value={harness} onChange={e => setHarness(e.target.value)}>
              <option value="">Session chooses</option>
              <option value="claude">claude</option>
              <option value="codex">codex</option>
              <option value="opencode">opencode</option>
            </select>
          </label>

          <label style={fieldStyle}>
            <span style={labelStyle}>Network</span>
            <select style={selectStyle} value={networkPolicy} onChange={e => setNetworkPolicy(e.target.value)}>
              <option value="full">Full</option>
              <option value="none">None (isolated)</option>
              <option value="restricted">Restricted (proxy)</option>
            </select>
          </label>

          <label style={fieldStyle}>
            <span style={labelStyle}>Credentials</span>
            <select style={selectStyle} value={credentialMode} onChange={e => setCredentialMode(e.target.value)}>
              <option value="all">All credentials</option>
              <option value="selected">Only selected</option>
            </select>
          </label>
        </div>

        {networkPolicy === 'restricted' && (
          <div style={hintStyle}>
            Restricted routes egress through <code>CLOUD_AGENTS_EGRESS_PROXY</code> if configured; the
            allowlisting proxy itself is a deployment concern.
          </div>
        )}

        {credentialMode === 'selected' && (
          <div style={grantsBoxStyle}>
            <div style={labelStyle}>Grant these credentials:</div>
            {credNames.length === 0 && (
              <div style={mutedStyle}>No credentials yet — add some on the Credentials page.</div>
            )}
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px' }}>
              {credNames.map(cn => (
                <label key={cn} style={grantChipStyle(grants.includes(cn))}>
                  <input
                    type="checkbox"
                    checked={grants.includes(cn)}
                    onChange={() => toggleGrant(cn)}
                    style={{ marginRight: '6px' }}
                  />
                  <code>{cn}</code>
                </label>
              ))}
            </div>
          </div>
        )}

        <div style={{ display: 'flex', gap: '8px' }}>
          <button
            style={{ ...saveBtnStyle, opacity: name.trim() && !saving ? 1 : 0.5 }}
            onClick={() => { void save(); }}
            disabled={!name.trim() || saving}
          >
            {saving ? 'Saving…' : editingId ? 'Update profile' : 'Create profile'}
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
      {!loading && profiles.length === 0 && <div style={mutedStyle}>No profiles yet — create one above.</div>}

      {profiles.map(p => (
        <div key={p.id} style={cardStyle}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div style={profileNameStyle}>{p.name}</div>
            <div style={{ display: 'flex', gap: '8px', flexShrink: 0 }}>
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
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
            <span style={badgeStyle}>harness: {p.harness || 'session'}</span>
            <span style={badgeStyle}>network: {p.networkPolicy}</span>
            <span style={badgeStyle}>
              creds: {p.credentialMode === 'all' ? 'all' : `${p.credentials.length} selected`}
            </span>
          </div>
          {p.credentialMode === 'selected' && p.credentials.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
              {p.credentials.map(c => (
                <code key={c} style={grantTagStyle}>{c}</code>
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

const titleStyle: React.CSSProperties = { fontSize: '18px', color: '#c9d1d9', margin: 0 };

const subtitleStyle: React.CSSProperties = { fontSize: '13px', color: '#8b949e', margin: 0, lineHeight: 1.5 };

const formStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '10px',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '14px',
};

const inputStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  outline: 'none',
};

const rowFieldsStyle: React.CSSProperties = { display: 'flex', gap: '10px', flexWrap: 'wrap' };

const fieldStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: '4px', flex: 1, minWidth: '160px' };

const labelStyle: React.CSSProperties = { fontSize: '11px', color: '#8b949e', textTransform: 'uppercase', letterSpacing: '0.04em' };

const selectStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
};

const hintStyle: React.CSSProperties = { fontSize: '12px', color: '#8b949e', lineHeight: 1.5 };

const grantsBoxStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '6px',
  padding: '10px',
};

const grantChipStyle = (on: boolean): React.CSSProperties => ({
  display: 'flex',
  alignItems: 'center',
  fontSize: '12px',
  color: on ? '#c9d1d9' : '#8b949e',
  background: on ? '#1f6feb22' : 'transparent',
  border: `1px solid ${on ? '#1f6feb' : '#30363d'}`,
  borderRadius: '6px',
  padding: '4px 8px',
  cursor: 'pointer',
});

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

const profileNameStyle: React.CSSProperties = { fontWeight: 600, fontSize: '14px', color: '#58a6ff' };

const badgeStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '10px',
  padding: '2px 8px',
};

const grantTagStyle: React.CSSProperties = { fontSize: '11px', color: '#79c0ff' };

const smallBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const errStyle: React.CSSProperties = { fontSize: '13px', color: '#f85149' };

const mutedStyle: React.CSSProperties = { fontSize: '13px', color: '#6e7681', textAlign: 'center', padding: '16px' };
