import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import type { Webhook } from '../types';

/// Run-completion webhooks: register https URLs that receive a notification
/// when a run finishes (succeeded / failed / cancelled). Delivery is performed
/// by an external worker that polls the server's pending-events queue, so
/// registering a URL here enables events to be queued for it.
export function Webhooks() {
  const [hooks, setHooks] = useState<Webhook[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [url, setUrl] = useState('');
  const [saving, setSaving] = useState(false);

  const reload = async () => {
    try {
      setHooks(await api.getWebhooks());
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load webhooks');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const register = async () => {
    if (!url.trim() || saving) return;
    setSaving(true);
    setError('');
    try {
      await api.registerWebhook(url.trim());
      setUrl('');
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to register webhook');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (h: Webhook) => {
    if (!confirm(`Delete webhook "${h.url}"?`)) return;
    setError('');
    try {
      await api.deleteWebhook(h.id);
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete webhook');
    }
  };

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Webhooks</h2>
      <p style={subtitleStyle}>
        Register an <code>https://</code> endpoint to be notified when a run completes. Events are queued
        server-side and delivered by an external worker (which polls the pending-events queue), so runs
        only enqueue events once at least one webhook is registered. Internal/loopback hosts are rejected.
      </p>

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="https://example.com/hooks/cloud-agents"
          value={url}
          onChange={e => setUrl(e.target.value)}
          maxLength={2048}
          aria-label="Webhook URL"
          onKeyDown={e => { if (e.key === 'Enter') void register(); }}
        />
        <button
          style={{ ...saveBtnStyle, opacity: url.trim() && !saving ? 1 : 0.5 }}
          onClick={() => { void register(); }}
          disabled={!url.trim() || saving}
        >
          {saving ? 'Adding…' : 'Add webhook'}
        </button>
      </div>

      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && hooks.length === 0 && <div style={mutedStyle}>No webhooks yet — add one above.</div>}

      {hooks.map(h => (
        <div key={h.id} style={rowStyle}>
          <code style={urlStyle}>{h.url}</code>
          <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
            <span style={metaStyle}>added {formatTime(h.createdAt)}</span>
            <button style={deleteBtnStyle} onClick={() => { void remove(h); }} aria-label={`Delete ${h.url}`}>
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

const urlStyle: React.CSSProperties = { fontSize: '12px', color: '#79c0ff', wordBreak: 'break-all' };

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
