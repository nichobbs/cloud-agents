import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { isGitHubConnected, listRepos, type GitHubRepo } from '../lib/github';
import { timeAgo } from '../lib/time';

/// Every repository the connected GitHub token can access, most recently
/// pushed first, with a client-side filter. "Start session" jumps to the New
/// Session form pre-filled with the repo's clone URL and default branch.
export function Repos() {
  const [repos, setRepos] = useState<GitHubRepo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const connected = isGitHubConnected();
  const navigate = useNavigate();

  // Mount-time load hits the 10-minute cache; the Refresh button bypasses it.
  const activeRef = useRef(true);
  useEffect(() => {
    activeRef.current = true;
    return () => {
      activeRef.current = false;
    };
  }, []);

  const load = useCallback((force: boolean) => {
    setLoading(true);
    listRepos(5, force)
      .then(rs => {
        if (activeRef.current) {
          setRepos(rs);
          setError('');
        }
      })
      .catch(err => {
        if (activeRef.current) {
          setError(err instanceof Error ? err.message : 'Failed to list repositories');
        }
      })
      .finally(() => {
        if (activeRef.current) setLoading(false);
      });
  }, []);

  // Always attempt the load: listRepos tries the backend proxy (vault token)
  // first, so the page can work with no locally-connected token at all. The
  // connect hint only appears when BOTH the proxy and the direct path failed.
  useEffect(() => {
    load(false);
  }, [load]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return repos;
    return repos.filter(
      r => r.fullName.toLowerCase().includes(q) || r.description.toLowerCase().includes(q),
    );
  }, [repos, query]);

  if (!connected && error && repos.length === 0) {
    return (
      <div style={pageStyle}>
        <h2 style={titleStyle}>Repositories</h2>
        <div style={emptyStyle}>
          Connect GitHub on the <Link to="/integrations" style={linkStyle}>Integrations</Link> page
          to browse every repository your token can access.
        </div>
      </div>
    );
  }

  return (
    <div style={pageStyle}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: '12px', flexWrap: 'wrap' }}>
        <h2 style={titleStyle}>Repositories</h2>
        <div style={{ display: 'flex', gap: '10px', alignItems: 'baseline' }}>
          <span style={countStyle}>
            {loading ? 'Loading…' : `${filtered.length} of ${repos.length}`}
          </span>
          <button
            style={refreshBtnStyle}
            onClick={() => load(true)}
            disabled={loading}
            title="Refetch from GitHub (bypasses the 10-minute cache)"
          >
            Refresh
          </button>
        </div>
      </div>
      <input
        style={searchStyle}
        placeholder="Filter repositories…"
        value={query}
        onChange={e => setQuery(e.target.value)}
        aria-label="Filter repositories"
      />
      {error && <div style={errStyle}>{error}</div>}
      {!loading && !error && filtered.length === 0 && (
        <div style={emptyStyle}>No repositories match.</div>
      )}
      {filtered.map(r => (
        <div key={r.fullName} style={rowStyle}>
          <div style={{ minWidth: 0, flex: 1 }}>
            <div style={{ display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' }}>
              <a href={r.htmlUrl} target="_blank" rel="noreferrer" style={repoNameStyle}>
                {r.fullName}
              </a>
              {r.private && <span style={privateBadgeStyle}>private</span>}
              {r.language && <span style={langStyle}>{r.language}</span>}
              <span style={metaStyle}>
                ★ {r.stars} · pushed {timeAgo(r.pushedAt) || '—'}
              </span>
            </div>
            {r.description && <div style={descStyle}>{r.description}</div>}
          </div>
          <button
            style={startBtnStyle}
            onClick={() =>
              navigate(
                `/sessions/new?repoUrl=${encodeURIComponent(r.cloneUrl)}&branch=${encodeURIComponent(r.defaultBranch)}`,
              )
            }
            title={`Start an agent session on ${r.fullName} (${r.defaultBranch})`}
          >
            Start session
          </button>
        </div>
      ))}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '860px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '10px',
};

const titleStyle: React.CSSProperties = { fontSize: '18px', color: '#c9d1d9', margin: 0 };

const countStyle: React.CSSProperties = { fontSize: '12px', color: '#8b949e' };

const searchStyle: React.CSSProperties = {
  padding: '8px 12px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  gap: '12px',
  alignItems: 'center',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const repoNameStyle: React.CSSProperties = {
  fontSize: '14px',
  fontWeight: 600,
  color: '#58a6ff',
  textDecoration: 'none',
};

const privateBadgeStyle: React.CSSProperties = {
  fontSize: '10px',
  fontWeight: 600,
  color: '#d29922',
  border: '1px solid #d29922',
  borderRadius: '999px',
  padding: '1px 7px',
};

const langStyle: React.CSSProperties = { fontSize: '11px', color: '#8b949e' };

const metaStyle: React.CSSProperties = { fontSize: '11px', color: '#6e7681' };

const descStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  marginTop: '4px',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const startBtnStyle: React.CSSProperties = {
  padding: '6px 12px',
  background: '#21262d',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
  flexShrink: 0,
};

const emptyStyle: React.CSSProperties = {
  color: '#6e7681',
  fontSize: '13px',
  textAlign: 'center',
  padding: '32px',
  border: '1px dashed #30363d',
  borderRadius: '8px',
};

const errStyle: React.CSSProperties = { fontSize: '13px', color: '#f85149' };

const refreshBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const linkStyle: React.CSSProperties = { color: '#58a6ff' };
