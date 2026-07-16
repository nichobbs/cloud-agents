/// Browser-side GitHub API client.
///
/// Uses the locally-held GitHub token (lib/connections.ts) — api.github.com is
/// CORS-enabled, and the Lyric backend has no outbound HTTPS, so the frontend
/// talks to GitHub directly. Powers the repo browser, the New Session repo
/// picker, and the per-session repo/PR/CI status panel.

import { getConnection } from './connections';

const API = 'https://api.github.com';

export interface GitHubRepo {
  fullName: string;
  description: string;
  private: boolean;
  defaultBranch: string;
  htmlUrl: string;
  cloneUrl: string;
  pushedAt: string;
  language: string;
  stars: number;
  openIssues: number;
}

export interface GitHubPull {
  number: number;
  title: string;
  state: string;
  draft: boolean;
  htmlUrl: string;
  headRef: string;
  baseRef: string;
  updatedAt: string;
  user: string;
}

export interface CheckRun {
  name: string;
  status: string; // queued | in_progress | completed
  conclusion: string; // success | failure | neutral | cancelled | skipped | timed_out | action_required | ''
  htmlUrl: string;
}

export interface BranchChecks {
  sha: string;
  total: number;
  runs: CheckRun[];
}

export function isGitHubConnected(): boolean {
  return getConnection('github').length > 0;
}

function headers(): HeadersInit {
  const token = getConnection('github');
  return {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${API}${path}`, { headers: headers() });
  if (!res.ok) throw new Error(`GitHub API ${res.status}: ${await res.text()}`);
  return res.json() as Promise<T>;
}

/** owner/repo parsed from an https GitHub URL, or null for non-GitHub remotes. */
export function parseGitHubUrl(repoUrl: string): { owner: string; repo: string } | null {
  try {
    const u = new URL(repoUrl);
    if (u.hostname !== 'github.com' && u.hostname !== 'www.github.com') return null;
    const parts = u.pathname.replace(/^\//, '').replace(/\.git$/, '').split('/');
    const owner = parts[0];
    const repo = parts[1];
    if (!owner || !repo) return null;
    return { owner, repo };
  } catch {
    return null;
  }
}

interface RawRepo {
  full_name: string;
  description: string | null;
  private: boolean;
  default_branch: string;
  html_url: string;
  clone_url: string;
  pushed_at: string;
  language: string | null;
  stargazers_count: number;
  open_issues_count: number;
}

function mapRepo(r: RawRepo): GitHubRepo {
  return {
    fullName: r.full_name,
    description: r.description ?? '',
    private: r.private,
    defaultBranch: r.default_branch,
    htmlUrl: r.html_url,
    cloneUrl: r.clone_url,
    pushedAt: r.pushed_at,
    language: r.language ?? '',
    stars: r.stargazers_count,
    openIssues: r.open_issues_count,
  };
}

/** The authenticated user's login (validates the token). */
export async function getViewerLogin(): Promise<string> {
  const me = await get<{ login: string }>('/user');
  return me.login;
}

/** Validate an explicit token (before it's stored). Returns the login. */
export async function validateGitHubToken(token: string): Promise<string> {
  const res = await fetch(`${API}/user`, {
    headers: {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      Authorization: `Bearer ${token}`,
    },
  });
  if (!res.ok) throw new Error(`GitHub rejected the token (${res.status})`);
  const me = (await res.json()) as { login: string };
  return me.login;
}

/** Every repo the token can access, most recently pushed first. Paginates up
 *  to `maxPages` × 100 repos. */
export async function listRepos(maxPages = 5): Promise<GitHubRepo[]> {
  const out: GitHubRepo[] = [];
  for (let page = 1; page <= maxPages; page++) {
    const batch = await get<RawRepo[]>(
      `/user/repos?per_page=100&page=${page}&sort=pushed&direction=desc`,
    );
    out.push(...batch.map(mapRepo));
    if (batch.length < 100) break;
  }
  return out;
}

export async function getRepo(owner: string, repo: string): Promise<GitHubRepo> {
  return mapRepo(await get<RawRepo>(`/repos/${owner}/${repo}`));
}

interface RawPull {
  number: number;
  title: string;
  state: string;
  draft: boolean;
  html_url: string;
  head: { ref: string };
  base: { ref: string };
  updated_at: string;
  user: { login: string } | null;
}

function mapPull(p: RawPull): GitHubPull {
  return {
    number: p.number,
    title: p.title,
    state: p.state,
    draft: p.draft,
    htmlUrl: p.html_url,
    headRef: p.head.ref,
    baseRef: p.base.ref,
    updatedAt: p.updated_at,
    user: p.user?.login ?? '',
  };
}

/** Open PRs, optionally narrowed to a head branch. */
export async function listPulls(owner: string, repo: string, headBranch?: string): Promise<GitHubPull[]> {
  const head = headBranch ? `&head=${encodeURIComponent(`${owner}:${headBranch}`)}` : '';
  const pulls = await get<RawPull[]>(`/repos/${owner}/${repo}/pulls?state=open&per_page=20${head}`);
  return pulls.map(mapPull);
}

/** CI check runs for the tip of a branch (or any ref). */
export async function getBranchChecks(owner: string, repo: string, ref: string): Promise<BranchChecks> {
  const commit = await get<{ sha: string }>(
    `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}`,
  );
  const checks = await get<{
    total_count: number;
    check_runs: { name: string; status: string; conclusion: string | null; html_url: string }[];
  }>(`/repos/${owner}/${repo}/commits/${commit.sha}/check-runs?per_page=50`);
  return {
    sha: commit.sha,
    total: checks.total_count,
    runs: checks.check_runs.map(c => ({
      name: c.name,
      status: c.status,
      conclusion: c.conclusion ?? '',
      htmlUrl: c.html_url,
    })),
  };
}

/** Roll a set of check runs up to one badge state. */
export function summariseChecks(runs: CheckRun[]): 'passing' | 'failing' | 'pending' | 'none' {
  if (runs.length === 0) return 'none';
  if (runs.some(r => r.status !== 'completed')) return 'pending';
  if (runs.some(r => ['failure', 'timed_out', 'action_required'].includes(r.conclusion))) {
    return 'failing';
  }
  return 'passing';
}
