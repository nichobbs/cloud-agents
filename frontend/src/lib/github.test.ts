import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

// Mock the backend proxy wrappers so the proxy-first/fallback ordering can be
// exercised without a server; the direct GitHub path is stubbed via fetch.
vi.mock('./api', () => ({
  proxyGithubRepos: vi.fn(),
  proxyGithubRepo: vi.fn(),
  proxyGithubPulls: vi.fn(),
  proxyGithubChecks: vi.fn(),
}));

import {
  proxyGithubChecks,
  proxyGithubPulls,
  proxyGithubRepo,
  proxyGithubRepos,
} from './api';
import {
  getBranchChecks,
  getRepo,
  listPulls,
  listRepos,
  parseGitHubUrl,
  summariseChecks,
  type CheckRun,
} from './github';

const run = (status: string, conclusion: string): CheckRun => ({
  name: 'ci',
  status,
  conclusion,
  htmlUrl: '',
});

describe('parseGitHubUrl', () => {
  it('parses owner/repo from https URLs, with and without .git', () => {
    expect(parseGitHubUrl('https://github.com/nichobbs/cloud-agents')).toEqual({
      owner: 'nichobbs',
      repo: 'cloud-agents',
    });
    expect(parseGitHubUrl('https://github.com/nichobbs/cloud-agents.git')).toEqual({
      owner: 'nichobbs',
      repo: 'cloud-agents',
    });
  });

  it('rejects non-GitHub hosts and malformed URLs', () => {
    expect(parseGitHubUrl('https://gitlab.com/a/b')).toBeNull();
    expect(parseGitHubUrl('https://github.com/only-owner')).toBeNull();
    expect(parseGitHubUrl('not a url')).toBeNull();
  });
});

const rawRepo = {
  full_name: 'owner/répo', // non-ASCII on purpose: the proxy path is UTF-8-clean
  description: null,
  private: true,
  default_branch: 'main',
  html_url: 'https://github.com/owner/repo',
  clone_url: 'https://github.com/owner/repo.git',
  pushed_at: '2026-07-01T00:00:00Z',
  language: null,
  stargazers_count: 3,
  open_issues_count: 1,
};

const rawPull = {
  number: 7,
  title: 'A change',
  state: 'open',
  draft: false,
  html_url: 'https://github.com/owner/repo/pull/7',
  head: { ref: 'feature' },
  base: { ref: 'main' },
  updated_at: '2026-07-01T00:00:00Z',
  user: { login: 'octocat' },
};

const rawChecks = {
  total_count: 1,
  check_runs: [
    { name: 'ci', status: 'completed', conclusion: 'success', html_url: 'https://ci', head_sha: 'sha123' },
  ],
};

function fetchOk(payload: unknown) {
  return vi.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve(payload),
  });
}

describe('proxy-first GitHub calls with direct fallback', () => {
  beforeEach(() => {
    localStorage.clear();
    vi.mocked(proxyGithubRepos).mockReset();
    vi.mocked(proxyGithubRepo).mockReset();
    vi.mocked(proxyGithubPulls).mockReset();
    vi.mocked(proxyGithubChecks).mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('getRepo maps the proxy passthrough payload without touching fetch', async () => {
    vi.mocked(proxyGithubRepo).mockResolvedValue(rawRepo);
    const fetchSpy = fetchOk(null);
    vi.stubGlobal('fetch', fetchSpy);
    const repo = await getRepo('owner', 'repo');
    expect(repo.fullName).toBe('owner/répo');
    expect(repo.description).toBe('');
    expect(repo.private).toBe(true);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('getRepo falls back to the direct GitHub call when the proxy errors', async () => {
    vi.mocked(proxyGithubRepo).mockRejectedValue(new Error('404 no GITHUB_TOKEN in the credential vault'));
    vi.stubGlobal('fetch', fetchOk(rawRepo));
    const repo = await getRepo('owner', 'repo');
    expect(repo.fullName).toBe('owner/répo');
    expect(fetch).toHaveBeenCalledWith(
      'https://api.github.com/repos/owner/repo',
      expect.anything(),
    );
  });

  it('listRepos pages the proxy and caches whichever path succeeded', async () => {
    vi.mocked(proxyGithubRepos).mockResolvedValue([rawRepo]);
    const fetchSpy = fetchOk(null);
    vi.stubGlobal('fetch', fetchSpy);
    const repos = await listRepos(5, true);
    expect(repos).toHaveLength(1);
    // Under 100 results stops pagination after page 1.
    expect(proxyGithubRepos).toHaveBeenCalledTimes(1);
    expect(proxyGithubRepos).toHaveBeenCalledWith(1);
    expect(fetchSpy).not.toHaveBeenCalled();
    // Second (non-forced) call is served from the 10-minute cache.
    vi.mocked(proxyGithubRepos).mockClear();
    const cached = await listRepos(5, false);
    expect(cached).toHaveLength(1);
    expect(proxyGithubRepos).not.toHaveBeenCalled();
  });

  it('listRepos falls back to the direct path when the proxy errors', async () => {
    vi.mocked(proxyGithubRepos).mockRejectedValue(new Error('500'));
    vi.stubGlobal('fetch', fetchOk([rawRepo]));
    const repos = await listRepos(5, true);
    expect(repos).toHaveLength(1);
    expect(fetch).toHaveBeenCalled();
  });

  it('listPulls prefers the proxy for a head branch and falls back on error', async () => {
    vi.mocked(proxyGithubPulls).mockResolvedValue([rawPull]);
    const fetchSpy = fetchOk(null);
    vi.stubGlobal('fetch', fetchSpy);
    const pulls = await listPulls('owner', 'repo', 'feature');
    expect(pulls[0]?.number).toBe(7);
    expect(pulls[0]?.headRef).toBe('feature');
    expect(fetchSpy).not.toHaveBeenCalled();

    // A slashed branch 404s on the proxy — the direct path takes over.
    vi.mocked(proxyGithubPulls).mockRejectedValue(new Error('404'));
    vi.stubGlobal('fetch', fetchOk([rawPull]));
    const fallback = await listPulls('owner', 'repo', 'feat/x');
    expect(fallback[0]?.number).toBe(7);
    expect(fetch).toHaveBeenCalled();
  });

  it('getBranchChecks derives the sha from the proxy check-runs payload', async () => {
    vi.mocked(proxyGithubChecks).mockResolvedValue(rawChecks);
    const fetchSpy = fetchOk(null);
    vi.stubGlobal('fetch', fetchSpy);
    const checks = await getBranchChecks('owner', 'repo', 'main');
    expect(checks.sha).toBe('sha123');
    expect(checks.total).toBe(1);
    expect(checks.runs[0]?.conclusion).toBe('success');
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('getBranchChecks falls back to the two-call direct path when the proxy errors', async () => {
    vi.mocked(proxyGithubChecks).mockRejectedValue(new Error('404'));
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ sha: 'direct-sha' }) })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve(rawChecks) });
    vi.stubGlobal('fetch', fetchSpy);
    const checks = await getBranchChecks('owner', 'repo', 'main');
    expect(checks.sha).toBe('direct-sha');
    expect(checks.runs).toHaveLength(1);
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });
});

describe('summariseChecks', () => {
  it('is none with no runs', () => {
    expect(summariseChecks([])).toBe('none');
  });

  it('is pending while any run is incomplete', () => {
    expect(summariseChecks([run('completed', 'success'), run('in_progress', '')])).toBe('pending');
  });

  it('is failing when any completed run failed', () => {
    expect(summariseChecks([run('completed', 'success'), run('completed', 'failure')])).toBe('failing');
    expect(summariseChecks([run('completed', 'timed_out')])).toBe('failing');
  });

  it('is passing when all completed runs succeeded or were skipped', () => {
    expect(summariseChecks([run('completed', 'success'), run('completed', 'skipped')])).toBe('passing');
  });
});
