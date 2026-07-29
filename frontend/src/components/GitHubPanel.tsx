import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  getBranchChecks,
  getRepo,
  isGitHubConnected,
  listPulls,
  parseGitHubUrl,
  summariseChecks,
  type BranchChecks,
  type GitHubPull,
  type GitHubRepo,
} from '../lib/github';
import { timeAgo } from '../lib/time';

interface GitHubPanelProps {
  repoUrl: string;
  branch: string;
}

/// Repo / PR / CI status for the session's repository and branch, fetched via
/// the backend proxy (vault token) with the locally-connected token as
/// fallback (see lib/github.ts). The fetch is always attempted; the connect
/// hint only shows when it fails AND no local token is connected (i.e. both
/// paths are unavailable). Hidden entirely for non-GitHub remotes.
export function GitHubPanel({ repoUrl, branch }: GitHubPanelProps) {
  const target = parseGitHubUrl(repoUrl);
  const connected = isGitHubConnected();
  const [repo, setRepo] = useState<GitHubRepo | null>(null);
  const [pulls, setPulls] = useState<GitHubPull[]>([]);
  const [checks, setChecks] = useState<BranchChecks | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [loadedFor, setLoadedFor] = useState('');

  const refresh = useCallback(async () => {
    if (!target) return;
    setLoading(true);
    setError('');
    try {
      const [repoInfo, branchPulls, branchChecks] = await Promise.all([
        getRepo(target.owner, target.repo),
        listPulls(target.owner, target.repo, branch).catch(() => [] as GitHubPull[]),
        getBranchChecks(target.owner, target.repo, branch).catch(() => null),
      ]);
      setRepo(repoInfo);
      setPulls(branchPulls);
      setChecks(branchChecks);
      setLoadedFor(`${target.owner}/${target.repo}#${branch}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'GitHub fetch failed');
    } finally {
      setLoading(false);
    }
  }, [target?.owner, target?.repo, branch]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!target) return;
    // Refetch when the session's repo/branch changes.
    const key = `${target.owner}/${target.repo}#${branch}`;
    if (key !== loadedFor) void refresh();
  }, [target?.owner, target?.repo, branch, loadedFor, refresh]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!target) return null;

  // Total failure with no local token: neither the backend proxy nor a direct
  // call can serve this panel — point at Integrations.
  if (!connected && error && !repo) {
    return (
      <div style={hintStyle}>
        Connect GitHub on the <Link to="/integrations" style={{ color: '#58a6ff' }}>Integrations</Link>{' '}
        page to see repo, PR and CI status here.
      </div>
    );
  }

  const ciState = checks ? summariseChecks(checks.runs) : 'none';

  return (
    <div style={panelStyle}>
      <div style={headerRowStyle}>
        <span style={headerStyle}>GitHub</span>
        {repo && (
          <span style={repoMetaStyle}>
            {repo.private ? 'private' : 'public'}
            {repo.language ? ` · ${repo.language}` : ''} · ★ {repo.stars} · {repo.openIssues} open issues
            {repo.pushedAt ? ` · pushed ${timeAgo(repo.pushedAt)}` : ''}
          </span>
        )}
        <div style={{ flex: 1 }} />
        <button style={refreshBtnStyle} onClick={() => { void refresh(); }} disabled={loading}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>

      {error && <div style={errStyle}>{error}</div>}

      <div style={rowStyle}>
        <span style={labelStyle}>CI on {branch}:</span>
        <span style={ciBadgeStyle(ciState)}>{ciState === 'none' ? 'no checks' : ciState}</span>
        {checks && checks.runs.length > 0 && (
          <span style={checksDetailStyle}>
            {checks.runs.filter(r => r.conclusion === 'success').length}/{checks.runs.length} passing
          </span>
        )}
      </div>
      {checks && ciState === 'failing' && (
        <div style={failedListStyle}>
          {checks.runs
            .filter(r => ['failure', 'timed_out', 'action_required'].includes(r.conclusion))
            .slice(0, 5)
            .map(r => (
              <a key={r.name} href={r.htmlUrl} target="_blank" rel="noreferrer" style={failedCheckStyle}>
                ✗ {r.name}
              </a>
            ))}
        </div>
      )}

      <div style={rowStyle}>
        <span style={labelStyle}>Pull requests:</span>
        {pulls.length === 0 && <span style={mutedStyle}>none open for this branch</span>}
      </div>
      {pulls.map(pr => (
        <a key={pr.number} href={pr.htmlUrl} target="_blank" rel="noreferrer" style={prRowStyle}>
          <span style={prBadgeStyle(pr.draft)}>{pr.draft ? 'draft' : 'open'}</span>
          <span style={prTitleStyle}>
            #{pr.number} {pr.title}
          </span>
          <span style={mutedStyle}>
            {pr.headRef} → {pr.baseRef} · {timeAgo(pr.updatedAt)}
          </span>
        </a>
      ))}
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const hintStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
  background: '#0d1117',
  border: '1px dashed #21262d',
  borderRadius: '8px',
  padding: '10px 14px',
};

const headerRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '10px',
  flexWrap: 'wrap',
};

const headerStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
  fontWeight: 600,
};

const repoMetaStyle: React.CSSProperties = { fontSize: '12px', color: '#8b949e' };

const refreshBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const rowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  fontSize: '12px',
  flexWrap: 'wrap',
};

const labelStyle: React.CSSProperties = { color: '#8b949e' };

const ciColor: Record<string, string> = {
  passing: '#3fb950',
  failing: '#f85149',
  pending: '#d29922',
  none: '#6e7681',
};

const ciBadgeStyle = (state: string): React.CSSProperties => ({
  color: ciColor[state] ?? '#8b949e',
  fontWeight: 600,
});

const checksDetailStyle: React.CSSProperties = { color: '#6e7681' };

const failedListStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '2px',
  paddingLeft: '8px',
};

const failedCheckStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#f85149',
  textDecoration: 'none',
};

const prRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  fontSize: '12px',
  textDecoration: 'none',
  padding: '4px 8px',
  borderRadius: '6px',
  background: '#161b22',
};

const prBadgeStyle = (draft: boolean): React.CSSProperties => ({
  fontSize: '10px',
  fontWeight: 600,
  color: draft ? '#8b949e' : '#3fb950',
  border: `1px solid ${draft ? '#8b949e' : '#3fb950'}`,
  borderRadius: '999px',
  padding: '1px 7px',
  flexShrink: 0,
});

const prTitleStyle: React.CSSProperties = {
  color: '#c9d1d9',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const mutedStyle: React.CSSProperties = { color: '#6e7681' };

const errStyle: React.CSSProperties = { fontSize: '12px', color: '#f85149' };
