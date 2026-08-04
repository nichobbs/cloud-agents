import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
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

vi.mock('../lib/api', () => ({
  api: {
    openPr: vi.fn(),
  },
}));

import { api } from '../lib/api';
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

function renderPanel(repoUrl = 'https://github.com/owner/repo', branch = 'feature', sessionId = 'sess-1') {
  return render(
    <MemoryRouter>
      <GitHubPanel sessionId={sessionId} repoUrl={repoUrl} branch={branch} />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.mocked(isGitHubConnected).mockReset().mockReturnValue(true);
  vi.mocked(getRepo).mockReset().mockResolvedValue(repo);
  vi.mocked(listPulls).mockReset().mockResolvedValue([pull]);
  vi.mocked(getBranchChecks).mockReset().mockResolvedValue(passingChecks);
  vi.mocked(api.openPr).mockReset();
});

describe('GitHubPanel', () => {
  it('renders nothing for a non-GitHub remote', () => {
    const { container } = renderPanel('https://gitlab.com/owner/repo');
    expect(container.innerHTML).toBe('');
    expect(getRepo).not.toHaveBeenCalled();
  });

  it('shows a connect hint when not connected AND the proxy-backed fetch fails', async () => {
    vi.mocked(isGitHubConnected).mockReturnValue(false);
    vi.mocked(getRepo).mockRejectedValue(new Error('404 no GITHUB_TOKEN in the credential vault'));
    renderPanel();
    // The fetch is attempted even without a local token (lib/github tries the
    // backend proxy first); only its total failure collapses to the hint.
    await waitFor(() => expect(screen.getByText(/Connect GitHub/)).toBeInTheDocument());
    expect(screen.getByRole('link', { name: 'Integrations' })).toHaveAttribute(
      'href',
      '/integrations',
    );
    expect(getRepo).toHaveBeenCalled();
  });

  it('renders the panel when the proxy serves data without a local token', async () => {
    vi.mocked(isGitHubConnected).mockReturnValue(false);
    renderPanel();
    await waitFor(() => expect(screen.getByText('passing')).toBeInTheDocument());
    expect(screen.getByRole('link', { name: /#42 Fix everything/ })).toBeInTheDocument();
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

  describe('Open PR (docs/phase10-auto-open-pr.md)', () => {
    it('calls api.openPr with the session id and shows the resulting PR link', async () => {
      const user = userEvent.setup();
      vi.mocked(api.openPr).mockResolvedValue({ url: 'https://github.com/owner/repo/pull/99', created: true });
      renderPanel('https://github.com/owner/repo', 'feature', 'sess-open-pr');
      await waitFor(() => expect(screen.getByText('passing')).toBeInTheDocument());

      await user.click(screen.getByRole('button', { name: 'Open PR' }));

      expect(api.openPr).toHaveBeenCalledWith('sess-open-pr');
      expect(await screen.findByText(/PR opened:/)).toBeInTheDocument();
      expect(screen.getByRole('link', { name: /PR opened:/ })).toHaveAttribute(
        'href',
        'https://github.com/owner/repo/pull/99',
      );
    });

    it('labels a reused PR distinctly from a newly created one', async () => {
      const user = userEvent.setup();
      vi.mocked(api.openPr).mockResolvedValue({ url: 'https://github.com/owner/repo/pull/42', created: false });
      renderPanel();
      await waitFor(() => expect(screen.getByText('passing')).toBeInTheDocument());

      await user.click(screen.getByRole('button', { name: 'Open PR' }));

      expect(await screen.findByText(/Already open:/)).toBeInTheDocument();
    });

    it('shows the backend error message when opening a PR fails', async () => {
      const user = userEvent.setup();
      vi.mocked(api.openPr).mockRejectedValue(new Error('400 no commits found on this branch'));
      renderPanel();
      await waitFor(() => expect(screen.getByText('passing')).toBeInTheDocument());

      await user.click(screen.getByRole('button', { name: 'Open PR' }));

      expect(await screen.findByText('400 no commits found on this branch')).toBeInTheDocument();
    });
  });
});
