import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { BranchChecks, GitHubPull, GitHubRepo } from '../lib/github';

// Mock only the side-effecting API calls; keep the pure helpers
// (parseGitHubUrl, summariseChecks) real so the panel's logic is exercised.
vi.mock('../lib/github', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/github')>()),
  isGitHubConnected: vi.fn(),
  getRepo: vi.fn(),
  listPulls: vi.fn(),
  getBranchChecks: vi.fn(),
}));

import { getBranchChecks, getRepo, isGitHubConnected, listPulls } from '../lib/github';
import { GitHubPanel } from './GitHubPanel';

const repo: GitHubRepo = {
  fullName: 'owner/repo',
  description: '',
  private: true,
  defaultBranch: 'main',
  htmlUrl: 'https://github.com/owner/repo',
  cloneUrl: 'https://github.com/owner/repo.git',
  pushedAt: new Date().toISOString(),
  language: 'TypeScript',
  stars: 7,
  openIssues: 3,
};

const pull: GitHubPull = {
  number: 42,
  title: 'Fix everything',
  state: 'open',
  draft: false,
  htmlUrl: 'https://github.com/owner/repo/pull/42',
  headRef: 'feature',
  baseRef: 'main',
  updatedAt: new Date().toISOString(),
  user: 'octocat',
};

const passingChecks: BranchChecks = {
  sha: 'abc123',
  total: 2,
  runs: [
    { name: 'build', status: 'completed', conclusion: 'success', htmlUrl: '' },
    { name: 'test', status: 'completed', conclusion: 'success', htmlUrl: '' },
  ],
};

function renderPanel(repoUrl = 'https://github.com/owner/repo', branch = 'feature') {
  return render(
    <MemoryRouter>
      <GitHubPanel repoUrl={repoUrl} branch={branch} />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.mocked(isGitHubConnected).mockReset().mockReturnValue(true);
  vi.mocked(getRepo).mockReset().mockResolvedValue(repo);
  vi.mocked(listPulls).mockReset().mockResolvedValue([pull]);
  vi.mocked(getBranchChecks).mockReset().mockResolvedValue(passingChecks);
});

describe('GitHubPanel', () => {
  it('renders nothing for a non-GitHub remote', () => {
    const { container } = renderPanel('https://gitlab.com/owner/repo');
    expect(container.innerHTML).toBe('');
    expect(getRepo).not.toHaveBeenCalled();
  });

  it('shows a connect hint (and fetches nothing) when GitHub is not connected', () => {
    vi.mocked(isGitHubConnected).mockReturnValue(false);
    renderPanel();
    expect(screen.getByText(/Connect GitHub/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Integrations' })).toHaveAttribute(
      'href',
      '/integrations',
    );
    expect(getRepo).not.toHaveBeenCalled();
  });

  it('shows repo info, CI state, and PRs for the session branch', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('passing')).toBeInTheDocument());
    // Repo meta line.
    expect(screen.getByText(/private/)).toBeInTheDocument();
    expect(screen.getByText(/3 open issues/)).toBeInTheDocument();
    // PR row links to the pull request.
    const prLink = screen.getByRole('link', { name: /#42 Fix everything/ });
    expect(prLink).toHaveAttribute('href', pull.htmlUrl);
    expect(getRepo).toHaveBeenCalledWith('owner', 'repo');
    expect(listPulls).toHaveBeenCalledWith('owner', 'repo', 'feature');
    expect(getBranchChecks).toHaveBeenCalledWith('owner', 'repo', 'feature');
  });

  it('rolls failing checks up to a failing badge with links to the failures', async () => {
    vi.mocked(getBranchChecks).mockResolvedValue({
      sha: 'abc123',
      total: 2,
      runs: [
        { name: 'build', status: 'completed', conclusion: 'success', htmlUrl: '' },
        { name: 'test', status: 'completed', conclusion: 'failure', htmlUrl: 'https://ci/test' },
      ],
    });
    renderPanel();
    await waitFor(() => expect(screen.getByText('failing')).toBeInTheDocument());
    expect(screen.getByRole('link', { name: /✗ test/ })).toHaveAttribute('href', 'https://ci/test');
  });

  it('surfaces a repo-fetch failure as an error, not a blank panel', async () => {
    vi.mocked(getRepo).mockRejectedValue(new Error('GitHub API 401: bad token'));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText(/GitHub API 401: bad token/)).toBeInTheDocument(),
    );
  });
});
