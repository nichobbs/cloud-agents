import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import { DEFAULT_HARNESS, HARNESSES, getHarness, type ModelOption } from '../lib/harnesses';
import { api } from '../lib/api';
import { enabledHarnesses } from '../lib/harnessAvailability';
import { isGitHubConnected, listRepos } from '../lib/github';
import { discoverModels } from '../lib/models';

export function NewSession() {
  // The Repos page links here with ?repoUrl=…&branch=… pre-filled.
  const [searchParams] = useSearchParams();
  const [repoUrl, setRepoUrl] = useState(searchParams.get('repoUrl') ?? '');
  const [branch, setBranch] = useState(searchParams.get('branch') ?? 'main');
  const [harness, setHarness] = useState(DEFAULT_HARNESS);
  const [model, setModel] = useState(getHarness(DEFAULT_HARNESS).defaultModel);
  const [models, setModels] = useState<ModelOption[]>(getHarness(DEFAULT_HARNESS).models);
  const [modelSource, setModelSource] = useState<'live' | 'static'>('static');
  const [repoSuggestions, setRepoSuggestions] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [enabledHarnessIds, setEnabledHarnessIds] = useState<Set<string> | null>(null);
  const { addSession } = useSessions();
  const navigate = useNavigate();

  // Which harnesses actually have a runner image on this deployment (#523).
  // null (unknown, e.g. an older backend) is treated as "every harness
  // available" — see lib/harnessAvailability.
  useEffect(() => {
    let active = true;
    enabledHarnesses().then(ids => {
      if (active) setEnabledHarnessIds(ids);
    });
    return () => {
      active = false;
    };
  }, []);

  // Live model discovery for the chosen harness (falls back to the static
  // catalog when no provider key is connected — see lib/models.ts).
  useEffect(() => {
    let active = true;
    discoverModels(harness).then(({ models: discovered, source }) => {
      if (!active) return;
      setModels(discovered);
      setModelSource(source);
      // Keep the current selection if the discovered list still has it.
      setModel(prev => (discovered.some(m => m.id === prev) ? prev : getHarness(harness).defaultModel));
    });
    return () => {
      active = false;
    };
  }, [harness]);

  // Clone-URL autocomplete from the connected GitHub account.
  useEffect(() => {
    if (!isGitHubConnected()) return;
    let active = true;
    listRepos(2)
      .then(rs => {
        if (active) setRepoSuggestions(rs.map(r => r.cloneUrl));
      })
      .catch(() => {
        /* suggestions are a bonus — the field still accepts any URL */
      });
    return () => {
      active = false;
    };
  }, []);

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
            list={repoSuggestions.length > 0 ? 'repo-suggestions' : undefined}
          />
          {repoSuggestions.length > 0 && (
            <datalist id="repo-suggestions">
              {repoSuggestions.map(url => (
                <option key={url} value={url} />
              ))}
            </datalist>
          )}
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
              {Object.entries(HARNESSES).map(([id, cfg]) => {
                const available = enabledHarnessIds === null || enabledHarnessIds.has(id);
                return (
                  <option key={id} value={id} disabled={!available}>
                    {cfg.label}{available ? '' : ' (not available on this deployment)'}
                  </option>
                );
              })}
            </select>
            {enabledHarnessIds !== null && !enabledHarnessIds.has(harness) && (
              <p style={hintStyle}>
                This harness has no runner image built on this deployment yet — starting a session will
                fail. Ask an operator to enable it (see deploy/COOLIFY.md).
              </p>
            )}
          </div>
          <div style={{ flex: 1 }}>
            <label style={labelStyle} htmlFor="model">
              Model{' '}
              <span
                style={modelSourceStyle}
                title={
                  modelSource === 'live'
                    ? 'Listed live from the provider API using your connected key'
                    : 'Static catalog — connect a provider key on the Integrations page for live discovery'
                }
              >
                {modelSource === 'live' ? '(live)' : '(catalog)'}
              </span>
            </label>
            <select
              id="model"
              style={selectStyle}
              value={model}
              onChange={e => setModel(e.target.value)}
              disabled={loading}
            >
              {models.map(m => (
                <option key={m.id} value={m.id}>{m.label}</option>
              ))}
            </select>
          </div>
        </div>

        {error && (
          <div style={errorStyle}>{error}</div>
        )}

        <div style={{ display: 'flex', gap: '10px', marginTop: '24px' }}>
          <button
            type="submit"
            style={primaryBtnStyle}
            disabled={loading || !repoUrl.trim() || (enabledHarnessIds !== null && !enabledHarnessIds.has(harness))}
          >
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

const hintStyle: React.CSSProperties = {
  margin: '6px 0 0',
  fontSize: '12px',
  color: '#d29922',
};

const modelSourceStyle: React.CSSProperties = {
  fontSize: '11px',
  fontWeight: 400,
  color: '#6e7681',
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
