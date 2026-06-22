import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import { DEFAULT_HARNESS, HARNESSES, getHarness } from '../lib/harnesses';
import { api } from '../lib/api';

export function NewSession() {
  const [repoUrl, setRepoUrl] = useState('');
  const [branch, setBranch] = useState('main');
  const [harness, setHarness] = useState(DEFAULT_HARNESS);
  const [model, setModel] = useState(getHarness(DEFAULT_HARNESS).defaultModel);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const { addSession } = useSessions();
  const navigate = useNavigate();

  const harnessConfig = getHarness(harness);

  const handleHarnessChange = (h: string) => {
    setHarness(h);
    setModel(getHarness(h).defaultModel);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!repoUrl.trim()) return;
    setLoading(true);
    setError('');
    try {
      const { sessionId } = await api.createSession({
        repoUrl: repoUrl.trim(),
        branch: branch.trim() || 'main',
        harness,
        model,
      });
      addSession({
        sessionId,
        repoUrl: repoUrl.trim(),
        branch: branch.trim() || 'main',
        createdAt: new Date().toISOString(),
        harness,
        model,
      });
      navigate(`/sessions/${sessionId}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setLoading(false);
    }
  };

  return (
    <div style={pageStyle}>
      <h1 style={h1Style}>New session</h1>
      <p style={{ color: '#8b949e', fontSize: '14px', marginTop: 0, marginBottom: '28px' }}>
        Clone a repository and start an agent session.
      </p>

      <form onSubmit={e => { void handleSubmit(e); }}>
        <div style={fieldStyle}>
          <label style={labelStyle} htmlFor="repoUrl">Repository URL</label>
          <input
            id="repoUrl"
            style={inputStyle}
            type="url"
            placeholder="https://github.com/owner/repo"
            value={repoUrl}
            onChange={e => setRepoUrl(e.target.value)}
            required
            disabled={loading}
          />
        </div>

        <div style={fieldStyle}>
          <label style={labelStyle} htmlFor="branch">Branch</label>
          <input
            id="branch"
            style={inputStyle}
            type="text"
            placeholder="main"
            value={branch}
            onChange={e => setBranch(e.target.value)}
            disabled={loading}
          />
        </div>

        <div style={{ display: 'flex', gap: '12px', marginBottom: '16px' }}>
          <div style={{ flex: 1 }}>
            <label style={labelStyle} htmlFor="harness">Agent</label>
            <select
              id="harness"
              style={selectStyle}
              value={harness}
              onChange={e => handleHarnessChange(e.target.value)}
              disabled={loading}
            >
              {Object.entries(HARNESSES).map(([id, cfg]) => (
                <option key={id} value={id}>{cfg.label}</option>
              ))}
            </select>
          </div>
          <div style={{ flex: 1 }}>
            <label style={labelStyle} htmlFor="model">Model</label>
            <select
              id="model"
              style={selectStyle}
              value={model}
              onChange={e => setModel(e.target.value)}
              disabled={loading}
            >
              {harnessConfig.models.map(m => (
                <option key={m.id} value={m.id}>{m.label}</option>
              ))}
            </select>
          </div>
        </div>

        {error && (
          <div style={errorStyle}>{error}</div>
        )}

        <div style={{ display: 'flex', gap: '10px', marginTop: '24px' }}>
          <button type="submit" style={primaryBtnStyle} disabled={loading || !repoUrl.trim()}>
            {loading ? 'Creating…' : 'Create session'}
          </button>
          <button
            type="button"
            style={secondaryBtnStyle}
            onClick={() => navigate('/sessions')}
            disabled={loading}
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '520px',
  margin: '0 auto',
  padding: '32px 24px',
};

const h1Style: React.CSSProperties = {
  margin: '0 0 8px',
  fontSize: '20px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const fieldStyle: React.CSSProperties = {
  marginBottom: '16px',
};

const labelStyle: React.CSSProperties = {
  display: 'block',
  fontSize: '13px',
  fontWeight: 500,
  color: '#c9d1d9',
  marginBottom: '6px',
};

const inputStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  padding: '7px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  boxSizing: 'border-box',
  outline: 'none',
};

const selectStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  padding: '7px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  boxSizing: 'border-box',
  outline: 'none',
  cursor: 'pointer',
};

const errorStyle: React.CSSProperties = {
  padding: '10px 14px',
  background: '#2d1417',
  border: '1px solid #f85149',
  borderRadius: '6px',
  color: '#f85149',
  fontSize: '13px',
  marginTop: '12px',
};

const primaryBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '14px',
  fontWeight: 500,
  cursor: 'pointer',
};

const secondaryBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '14px',
  cursor: 'pointer',
};
