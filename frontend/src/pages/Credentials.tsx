import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import type { Credential } from '../types';

/// The credential store: add named secrets (GitHub token, cloud credentials,
/// arbitrary env vars) that are injected into every runner container. Values
/// are write-only — the server never returns a stored secret, so this page can
/// list names but never display a value.
/// Unlike every other RequireAuth-guarded route, the backend never falls
/// back to open access for /api/credentials — CloudAgents.Auth.authorizeSecret
/// always denies with AuthNotConfigured when no static token is set,
/// regardless of GitHub OAuth state (credential storage must never run
/// unauthenticated). RequireAuth itself still renders this page unguarded on
/// a deployment with no auth configured at all (matching the *general*
/// backend fallback other routes use), so every request this page makes
/// then 401s. Detecting that specific response here — rather than teaching
/// RequireAuth a route-specific exception — lets this page show a clear
/// "not available on this deployment" state instead of a raw fetch error
/// (#503).
function isAuthNotConfiguredError(err: unknown): boolean {
  return err instanceof Error && err.message.startsWith('401') && err.message.includes('authentication is not configured');
}

export function Credentials() {
  const [names, setNames] = useState<Credential[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [unavailable, setUnavailable] = useState(false);
  const [name, setName] = useState('');
  const [value, setValue] = useState('');
  const [saving, setSaving] = useState(false);

  const reload = async () => {
    try {
      setNames(await api.getCredentialNames());
      setError('');
    } catch (err) {
      if (isAuthNotConfiguredError(err)) {
        setUnavailable(true);
      } else {
        setError(err instanceof Error ? err.message : 'Failed to load credentials');
      }
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const save = async () => {
    if (!name.trim() || !value || saving) return;
    setSaving(true);
    setError('');
    try {
      await api.putCredential(name.trim(), value);
      setName('');
      setValue('');
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save credential');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (credName: string) => {
    if (!confirm(`Delete credential "${credName}"? Containers will no longer receive it.`)) return;
    setError('');
    try {
      await api.deleteCredential(credName);
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete credential');
    }
  };

  if (unavailable) {
    return (
      <div style={pageStyle}>
        <h2 style={titleStyle}>Credentials</h2>
        <div style={mutedStyle}>
          Credential storage isn't available on this deployment — authentication isn't
          configured, and credential routes always require it, unlike the rest of the app.
          <br />
          <Link to="/" style={{ color: '#58a6ff' }}>Back home</Link>
        </div>
      </div>
    );
  }

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Credentials</h2>
      <p style={subtitleStyle}>
        Secrets stored here are encrypted at rest and injected as environment variables into every
        runner container (e.g. <code>GITHUB_TOKEN</code>, <code>GOOGLE_APPLICATION_CREDENTIALS</code>).
        Values are write-only — they are never shown again after saving. For provider API keys,
        prefer the <Link to="/integrations" style={{ color: '#58a6ff' }}>Integrations</Link> page:
        it validates the key, uploads it here under its canonical name, and unlocks live model
        discovery and GitHub panels. <code>scripts/upload-credentials.sh</code> can auto-import
        credentials from your local harness installs (Claude Code, Codex, OpenCode, Gemini, gh).
      </p>

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="NAME (e.g. GITHUB_TOKEN)"
          value={name}
          onChange={e => setName(e.target.value)}
          maxLength={128}
          aria-label="Credential name"
          autoComplete="off"
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
        />
        <input
          style={inputStyle}
          type="password"
          placeholder="Secret value"
          value={value}
          onChange={e => setValue(e.target.value)}
          aria-label="Credential value"
          autoComplete="new-password"
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
        />
        <button
          style={{ ...saveBtnStyle, opacity: name.trim() && value && !saving ? 1 : 0.5 }}
          onClick={() => { void save(); }}
          disabled={!name.trim() || !value || saving}
        >
          {saving ? 'Saving…' : 'Save credential'}
        </button>
      </div>

      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && names.length === 0 && (
        <div style={mutedStyle}>No credentials yet — add one above.</div>
      )}

      {names.map(c => (
        <div key={c.name} style={rowStyle}>
          <code style={nameStyle}>{c.name}</code>
          <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
            <span style={metaStyle}>updated {formatTime(c.updatedAt)}</span>
            <button
              style={deleteBtnStyle}
              onClick={() => { void remove(c.name); }}
              aria-label={`Delete ${c.name}`}
            >
              Delete
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

function formatTime(epochMillis: string): string {
  const n = Number(epochMillis);
  if (!Number.isFinite(n) || n <= 0) return 'unknown';
  return new Date(n).toLocaleString();
}

const pageStyle: React.CSSProperties = {
  maxWidth: '900px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
};

const titleStyle: React.CSSProperties = { fontSize: '18px', color: '#c9d1d9', margin: 0 };

const subtitleStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#8b949e',
  margin: 0,
  lineHeight: 1.5,
};

const formStyle: React.CSSProperties = {
  display: 'flex',
  gap: '8px',
  flexWrap: 'wrap',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '14px',
};

const inputStyle: React.CSSProperties = {
  flex: 1,
  minWidth: '180px',
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
};

const saveBtnStyle: React.CSSProperties = {
  padding: '8px 16px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '10px 14px',
};

const nameStyle: React.CSSProperties = { fontSize: '13px', color: '#79c0ff' };

const metaStyle: React.CSSProperties = { fontSize: '11px', color: '#6e7681' };

const deleteBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #f85149',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const errStyle: React.CSSProperties = { fontSize: '13px', color: '#f85149' };

const mutedStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#6e7681',
  textAlign: 'center',
  padding: '16px',
};
