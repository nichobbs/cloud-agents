import { useEffect, useState } from 'react';
import { importsApi } from '../lib/imports';
import type { ImportToken } from '../lib/imports';

/// Claude session import (docs/claude-session-import.md): manage the tokens an
/// importer session uses to send findings about your Claude Code cloud
/// sessions. Findings land in the Inbox; imported sessions are read-only.
export function Imports() {
  const [tokens, setTokens] = useState<ImportToken[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [label, setLabel] = useState('claude importer');
  const [saving, setSaving] = useState(false);
  const [secret, setSecret] = useState('');
  const [ccrId, setCcrId] = useState('');
  const [notice, setNotice] = useState('');

  const reload = async () => {
    try {
      setTokens(await importsApi.tokens());
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load import tokens');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const create = async () => {
    if (!label.trim() || saving) return;
    setSaving(true);
    setError('');
    try {
      const created = await importsApi.createToken(label.trim());
      setSecret(created.secret);
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create import token');
    } finally {
      setSaving(false);
    }
  };

  const revoke = async (t: ImportToken) => {
    if (!confirm(`Revoke import token "${t.label}"? An importer using it stops working.`)) return;
    setError('');
    try {
      await importsApi.revokeToken(t.id);
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to revoke import token');
    }
  };

  const allowAgain = async () => {
    if (!ccrId.trim()) return;
    setError('');
    setNotice('');
    try {
      await importsApi.clearTombstone(ccrId.trim());
      setNotice(`${ccrId.trim()} can be imported again.`);
      setCcrId('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to re-allow the session');
    }
  };

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Claude session import</h2>
      <p style={subtitleStyle}>
        An importer, a Claude Code scheduled task, reads your Claude Code cloud sessions and sends
        findings (shortcuts, deviations, open questions, blockers) here. They appear in the Inbox under
        a read-only imported session. Create a token below and store it as a network secret for{' '}
        <code>agents.playdium.games</code> in the importer's cloud environment; the setup is in{' '}
        <code>deploy/importer/</code>. A token can only send findings: it cannot read or start sessions.
      </p>

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="Label"
          value={label}
          onChange={e => setLabel(e.target.value)}
          maxLength={100}
          aria-label="Token label"
          onKeyDown={e => { if (e.key === 'Enter') void create(); }}
        />
        <button
          style={{ ...saveBtnStyle, opacity: label.trim() && !saving ? 1 : 0.5 }}
          onClick={() => { void create(); }}
          disabled={!label.trim() || saving}
        >
          {saving ? 'Creating…' : 'Create token'}
        </button>
      </div>

      {secret && (
        <div style={secretStyle} role="status">
          <div>Copy this token now. It is not shown again.</div>
          <code style={secretCodeStyle} data-testid="import-secret">{secret}</code>
          <button style={linkBtnStyle} onClick={() => setSecret('')}>Done</button>
        </div>
      )}

      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && tokens.length === 0 && <div style={mutedStyle}>No import tokens yet.</div>}

      {tokens.map(t => (
        <div key={t.id} style={rowStyle}>
          <span style={labelStyle}>{t.label}{t.revoked ? ' (revoked)' : ''}</span>
          <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
            <span style={metaStyle}>
              created {formatTime(t.createdAt)} · last used {t.lastUsedAt ? formatTime(t.lastUsedAt) : 'never'}
            </span>
            {!t.revoked && (
              <button style={deleteBtnStyle} onClick={() => { void revoke(t); }} aria-label={`Revoke ${t.label}`}>
                Revoke
              </button>
            )}
          </div>
        </div>
      ))}

      <h3 style={sectionStyle}>Re-allow a deleted session</h3>
      <p style={subtitleStyle}>
        Deleting an imported session stops the importer bringing it back. Enter its Claude Code session id
        (<code>session_…</code>) to allow it to be imported again.
      </p>
      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="session_…"
          value={ccrId}
          onChange={e => setCcrId(e.target.value)}
          maxLength={100}
          aria-label="Claude Code session id"
        />
        <button style={{ ...saveBtnStyle, opacity: ccrId.trim() ? 1 : 0.5 }} onClick={() => { void allowAgain(); }} disabled={!ccrId.trim()}>
          Allow import
        </button>
      </div>
      {notice && <div style={mutedStyle}>{notice}</div>}
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

const sectionStyle: React.CSSProperties = { fontSize: '15px', color: '#c9d1d9', margin: '12px 0 0' };

const subtitleStyle: React.CSSProperties = { fontSize: '13px', color: '#8b949e', margin: 0, lineHeight: 1.5 };

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
  minWidth: '240px',
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

const secretStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
  background: '#0d1117',
  border: '1px solid #d29922',
  borderRadius: '8px',
  padding: '12px 14px',
  fontSize: '13px',
  color: '#c9d1d9',
};

const secretCodeStyle: React.CSSProperties = { fontSize: '12px', color: '#79c0ff', wordBreak: 'break-all' };

const linkBtnStyle: React.CSSProperties = {
  alignSelf: 'flex-start',
  background: 'transparent',
  border: 'none',
  color: '#58a6ff',
  fontSize: '12px',
  cursor: 'pointer',
  padding: 0,
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  gap: '10px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '10px 14px',
};

const labelStyle: React.CSSProperties = { fontSize: '13px', color: '#c9d1d9' };

const metaStyle: React.CSSProperties = { fontSize: '11px', color: '#6e7681', whiteSpace: 'nowrap' };

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

const mutedStyle: React.CSSProperties = { fontSize: '13px', color: '#6e7681', textAlign: 'center', padding: '16px' };
