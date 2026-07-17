import { useCallback, useEffect, useState } from 'react';
import { api, type SessionRepo } from '../lib/api';
import { isGitHubConnected, listRepos, parseGitHubUrl, type GitHubRepo } from '../lib/github';

interface LinkedReposPanelProps {
  sessionId: string;
  primaryRepoUrl: string;
  primaryBranch: string;
}

/** A short "owner/repo" label for a repo URL, falling back to the raw URL for
 *  non-GitHub remotes. Exported for direct unit testing. */
export function repoLabel(repoUrl: string): string {
  const parsed = parseGitHubUrl(repoUrl);
  return parsed ? `${parsed.owner}/${parsed.repo}` : repoUrl;
}

/// The repositories linked to a session: its primary repo plus any extras an
/// agent can work across in one run (multi-repo sessions). The extras are
/// listed with a remove control, and an "Add repository" form links more — from
/// the user's GitHub repos when connected, or a raw https URL otherwise. The
/// whole panel hides itself when the backend has no /repos routes (an older
/// server 404s the initial GET), so it degrades gracefully.
export function LinkedReposPanel({ sessionId, primaryRepoUrl, primaryBranch }: LinkedReposPanelProps) {
  const [repos, setRepos] = useState<SessionRepo[]>([]);
  // null = still loading; false = available; true = backend without the routes.
  const [unavailable, setUnavailable] = useState<boolean | null>(null);
  const [adding, setAdding] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [url, setUrl] = useState('');
  const [branch, setBranch] = useState('');
  const [error, setError] = useState('');
  const [ghRepos, setGhRepos] = useState<GitHubRepo[]>([]);
  const connected = isGitHubConnected();

  const load = useCallback(async () => {
    try {
      setRepos(await api.listSessionRepos(sessionId));
      setUnavailable(false);
    } catch {
      // Older backend without the routes (404), or a transient failure — hide
      // the panel body rather than surfacing a scary error for a feature the
      // server may simply not have.
      setUnavailable(true);
    }
  }, [sessionId]);

  useEffect(() => {
    void load();
  }, [load]);

  // Lazily fetch the user's GitHub repos the first time the add form opens (only
  // when connected). Best-effort: the free-text URL field still works if this
  // fails, so a listing error just leaves the picker empty.
  useEffect(() => {
    if (!showForm || !connected || ghRepos.length > 0) return;
    let active = true;
    listRepos()
      .then(rs => {
        if (active) setGhRepos(rs);
      })
      .catch(() => {
        /* repo listing unavailable — the URL field still works */
      });
    return () => {
      active = false;
    };
  }, [showForm, connected, ghRepos.length]);

  const handleAdd = async () => {
    const repoUrl = url.trim();
    if (!repoUrl || adding) return;
    setAdding(true);
    setError('');
    try {
      await api.addSessionRepo(sessionId, repoUrl, branch.trim());
      setUrl('');
      setBranch('');
      setShowForm(false);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to link repository');
    } finally {
      setAdding(false);
    }
  };

  const handleRemove = async (repo: SessionRepo) => {
    if (!confirm(`Unlink ${repoLabel(repo.repoUrl)} from this session?`)) return;
    try {
      await api.removeSessionRepo(sessionId, repo.id);
      await load();
    } catch (err) {
      alert(err instanceof Error ? `Failed to unlink: ${err.message}` : 'Failed to unlink');
    }
  };

  // Hidden entirely on an older backend (or while the first load is in flight,
  // to avoid a flash of an empty panel that then disappears).
  if (unavailable === null || unavailable) return null;

  return (
    <div style={panelStyle}>
      <div style={headerStyle}>
        <span style={titleStyle}>Linked repositories</span>
        <button
          style={addBtnStyle}
          onClick={() => {
            setShowForm(v => !v);
            setError('');
          }}
        >
          {showForm ? 'Close' : 'Add repository'}
        </button>
      </div>

      <div style={rowStyle}>
        <span style={primaryBadgeStyle}>primary</span>
        <span style={repoNameCellStyle}>{repoLabel(primaryRepoUrl)}</span>
        <span style={branchCellStyle}>{primaryBranch || 'default'}</span>
        <span style={{ width: '58px', flexShrink: 0 }} />
      </div>

      {repos.map(r => (
        <div key={r.id} style={rowStyle}>
          <span style={extraBadgeStyle}>repo</span>
          <span style={repoNameCellStyle} title={r.repoUrl}>{repoLabel(r.repoUrl)}</span>
          <span style={branchCellStyle}>{r.branch || 'default'}</span>
          <button style={removeBtnStyle} onClick={() => { void handleRemove(r); }}>
            Remove
          </button>
        </div>
      ))}

      {showForm && (
        <div style={formStyle}>
          {connected && ghRepos.length > 0 && (
            <select
              style={inputStyle}
              value=""
              onChange={e => {
                const picked = ghRepos.find(g => g.cloneUrl === e.target.value);
                if (picked) {
                  setUrl(picked.cloneUrl);
                  setBranch(picked.defaultBranch);
                }
              }}
              aria-label="Pick one of your GitHub repositories"
            >
              <option value="">Pick from your GitHub repos…</option>
              {ghRepos.map(g => (
                <option key={g.fullName} value={g.cloneUrl}>{g.fullName}</option>
              ))}
            </select>
          )}
          <input
            style={inputStyle}
            placeholder="https://github.com/owner/repo"
            value={url}
            onChange={e => setUrl(e.target.value)}
            aria-label="Repository URL"
          />
          <input
            style={branchInputStyle}
            placeholder="branch (optional)"
            value={branch}
            onChange={e => setBranch(e.target.value)}
            aria-label="Branch (optional)"
          />
          <button
            style={{ ...confirmBtnStyle, opacity: url.trim() && !adding ? 1 : 0.5 }}
            onClick={() => { void handleAdd(); }}
            disabled={!url.trim() || adding}
          >
            {adding ? 'Linking…' : 'Link'}
          </button>
        </div>
      )}

      {error && <div role="alert" style={errorStyle}>{error}</div>}
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const headerStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
};

const titleStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const addBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#58a6ff',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '10px',
  fontSize: '13px',
  padding: '4px 0',
  borderTop: '1px solid #161b22',
};

const badgeBase: React.CSSProperties = {
  fontSize: '10px',
  fontWeight: 600,
  borderRadius: '4px',
  padding: '1px 6px',
  minWidth: '48px',
  textAlign: 'center',
  flexShrink: 0,
  textTransform: 'uppercase',
  letterSpacing: '0.03em',
};

const primaryBadgeStyle: React.CSSProperties = {
  ...badgeBase,
  color: '#3fb950',
  border: '1px solid #238636',
  background: 'rgba(35, 134, 54, 0.15)',
};

const extraBadgeStyle: React.CSSProperties = {
  ...badgeBase,
  color: '#8b949e',
  border: '1px solid #30363d',
  background: '#161b22',
};

const repoNameCellStyle: React.CSSProperties = {
  flex: 1,
  color: '#c9d1d9',
  fontFamily: 'monospace',
  whiteSpace: 'nowrap',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
};

const branchCellStyle: React.CSSProperties = {
  color: '#79c0ff',
  fontFamily: 'monospace',
  fontSize: '12px',
  flexShrink: 0,
};

const removeBtnStyle: React.CSSProperties = {
  padding: '2px 8px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '11px',
  cursor: 'pointer',
  flexShrink: 0,
};

const formStyle: React.CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  gap: '8px',
  alignItems: 'center',
  paddingTop: '8px',
  borderTop: '1px solid #161b22',
};

const inputStyle: React.CSSProperties = {
  flex: '1 1 200px',
  minWidth: '160px',
  padding: '6px 10px',
  background: '#010409',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
  boxSizing: 'border-box',
};

const branchInputStyle: React.CSSProperties = {
  ...inputStyle,
  flex: '0 1 150px',
};

const confirmBtnStyle: React.CSSProperties = {
  padding: '6px 14px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  fontWeight: 500,
  cursor: 'pointer',
  flexShrink: 0,
};

const errorStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#f85149',
  paddingTop: '4px',
};
