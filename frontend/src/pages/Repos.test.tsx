import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom';
import type { GitHubRepo } from '../lib/github';

vi.mock('../lib/github', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/github')>()),
  isGitHubConnected: vi.fn(),
  listRepos: vi.fn(),
}));

import { isGitHubConnected, listRepos } from '../lib/github';
import { Repos } from './Repos';

function makeRepo(over: Partial<GitHubRepo>): GitHubRepo {
  return {
    fullName: 'owner/alpha',
    description: 'first repo',
    private: false,
    defaultBranch: 'main',
    htmlUrl: 'https://github.com/owner/alpha',
    cloneUrl: 'https://github.com/owner/alpha.git',
    pushedAt: new Date().toISOString(),
    language: 'TypeScript',
    stars: 1,
    openIssues: 0,
    ...over,
  };
}

/** Probe rendered at /sessions/new so the test can assert the prefill params. */
function NewSessionProbe() {
  const location = useLocation();
  return <div data-testid="new-session-probe">{location.search}</div>;
}

function renderRepos() {
  return render(
    <MemoryRouter initialEntries={['/repos']}>
      <Routes>
        <Route path="/repos" element={<Repos />} />
        <Route path="/sessions/new" element={<NewSessionProbe />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.mocked(isGitHubConnected).mockReset().mockReturnValue(true);
  vi.mocked(listRepos)
    .mockReset()
    .mockResolvedValue([
      makeRepo({}),
      makeRepo({ fullName: 'owner/beta', cloneUrl: 'https://github.com/owner/beta.git', description: 'second repo', private: true, defaultBranch: 'develop' }),
    ]);
});

describe('Repos', () => {
  it('points at Integrations only when both the proxy and the direct path fail', async () => {
    vi.mocked(isGitHubConnected).mockReturnValue(false);
    vi.mocked(listRepos).mockRejectedValue(new Error('404 no GITHUB_TOKEN in the credential vault'));
    renderRepos();
    // The load is attempted even without a local token (the backend proxy may
    // have a vault token); the hint appears only after that total failure.
    await waitFor(() =>
      expect(screen.getByRole('link', { name: 'Integrations' })).toHaveAttribute(
        'href',
        '/integrations',
      ),
    );
    expect(listRepos).toHaveBeenCalled();
  });

  it('lists repos via the backend proxy even when no local token is connected', async () => {
    vi.mocked(isGitHubConnected).mockReturnValue(false);
    renderRepos();
    await waitFor(() => expect(screen.getByText('owner/alpha')).toBeInTheDocument());
    expect(screen.getByText('owner/beta')).toBeInTheDocument();
  });

  it('lists accessible repos with metadata', async () => {
    renderRepos();
    await waitFor(() => expect(screen.getByText('owner/alpha')).toBeInTheDocument());
    expect(screen.getByText('owner/beta')).toBeInTheDocument();
    expect(screen.getByText('private')).toBeInTheDocument(); // beta only
    expect(screen.getByText('2 of 2')).toBeInTheDocument();
    // Mount-time load uses the cache (force=false).
    expect(listRepos).toHaveBeenCalledWith(5, false);
  });

  it('filters by name/description client-side', async () => {
    renderRepos();
    await waitFor(() => expect(screen.getByText('owner/alpha')).toBeInTheDocument());
    await userEvent.type(screen.getByLabelText('Filter repositories'), 'second');
    expect(screen.queryByText('owner/alpha')).not.toBeInTheDocument();
    expect(screen.getByText('owner/beta')).toBeInTheDocument();
    expect(screen.getByText('1 of 2')).toBeInTheDocument();
  });

  it('Refresh bypasses the cache', async () => {
    renderRepos();
    await waitFor(() => expect(screen.getByText('owner/alpha')).toBeInTheDocument());
    await userEvent.click(screen.getByRole('button', { name: 'Refresh' }));
    await waitFor(() => expect(listRepos).toHaveBeenLastCalledWith(5, true));
  });

  it('Start session navigates to New Session pre-filled with clone URL and default branch', async () => {
    renderRepos();
    await waitFor(() => expect(screen.getByText('owner/beta')).toBeInTheDocument());
    await userEvent.click(
      screen.getByTitle('Start an agent session on owner/beta (develop)'),
    );
    const probe = await screen.findByTestId('new-session-probe');
    expect(probe.textContent).toContain(
      `repoUrl=${encodeURIComponent('https://github.com/owner/beta.git')}`,
    );
    expect(probe.textContent).toContain('branch=develop');
  });

  it('surfaces listing failures', async () => {
    vi.mocked(listRepos).mockRejectedValue(new Error('GitHub API 403: rate limited'));
    renderRepos();
    await waitFor(() =>
      expect(screen.getByText(/rate limited/)).toBeInTheDocument(),
    );
  });
});
