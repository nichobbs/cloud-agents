import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import type { SessionRepo } from '../lib/api';

// Mock the API surface the panel calls; the GitHub helpers are mocked so the
// panel doesn't reach the network for the (optional) repo picker.
vi.mock('../lib/api', () => ({
  api: {
    listSessionRepos: vi.fn(),
    addSessionRepo: vi.fn(),
    removeSessionRepo: vi.fn(),
  },
}));
vi.mock('../lib/github', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/github')>()),
  isGitHubConnected: vi.fn(() => false),
  listRepos: vi.fn(),
}));

import { api } from '../lib/api';
import { LinkedReposPanel, repoLabel } from './LinkedReposPanel';

const extra: SessionRepo = { id: 'r1', repoUrl: 'https://github.com/nic/extra', branch: 'dev' };

function renderPanel() {
  return render(
    <LinkedReposPanel
      sessionId="s1"
      primaryRepoUrl="https://github.com/nic/primary"
      primaryBranch="main"
    />,
  );
}

describe('repoLabel', () => {
  it('shows owner/repo for a GitHub URL', () => {
    expect(repoLabel('https://github.com/nic/cloud-agents')).toBe('nic/cloud-agents');
    expect(repoLabel('https://github.com/nic/cloud-agents.git')).toBe('nic/cloud-agents');
  });
  it('falls back to the raw URL for a non-GitHub remote', () => {
    expect(repoLabel('https://gitlab.com/nic/thing')).toBe('https://gitlab.com/nic/thing');
  });
});

describe('LinkedReposPanel', () => {
  beforeEach(() => {
    vi.mocked(api.listSessionRepos).mockReset();
    vi.mocked(api.addSessionRepo).mockReset();
    vi.mocked(api.removeSessionRepo).mockReset();
  });

  it('lists the primary repo and any linked extras', async () => {
    vi.mocked(api.listSessionRepos).mockResolvedValue([extra]);
    renderPanel();
    await waitFor(() => expect(screen.getByText('nic/primary')).toBeInTheDocument());
    expect(screen.getByText('nic/extra')).toBeInTheDocument();
    // The primary repo is badged and its branch shown.
    expect(screen.getByText('primary')).toBeInTheDocument();
    expect(screen.getByText('dev')).toBeInTheDocument();
  });

  it('hides itself when the backend has no /repos routes (404)', async () => {
    vi.mocked(api.listSessionRepos).mockRejectedValue(new Error('404 not found'));
    const { container } = renderPanel();
    await waitFor(() => expect(api.listSessionRepos).toHaveBeenCalled());
    // Nothing rendered — no "Linked repositories" heading.
    expect(screen.queryByText('Linked repositories')).not.toBeInTheDocument();
    expect(container).toBeEmptyDOMElement();
  });

  it('links a repo via the form, then refreshes the list', async () => {
    vi.mocked(api.listSessionRepos)
      .mockResolvedValueOnce([]) // initial load
      .mockResolvedValueOnce([extra]); // after add
    vi.mocked(api.addSessionRepo).mockResolvedValue(extra);
    renderPanel();
    await waitFor(() => expect(screen.getByText('Add repository')).toBeInTheDocument());

    fireEvent.click(screen.getByText('Add repository'));
    fireEvent.change(screen.getByLabelText('Repository URL'), {
      target: { value: 'https://github.com/nic/extra' },
    });
    fireEvent.change(screen.getByLabelText('Branch (optional)'), { target: { value: 'dev' } });
    fireEvent.click(screen.getByText('Link'));

    await waitFor(() =>
      expect(api.addSessionRepo).toHaveBeenCalledWith('s1', 'https://github.com/nic/extra', 'dev'),
    );
    await waitFor(() => expect(screen.getByText('nic/extra')).toBeInTheDocument());
  });

  it('surfaces a backend validation error inline without hiding the panel', async () => {
    vi.mocked(api.listSessionRepos).mockResolvedValue([]);
    vi.mocked(api.addSessionRepo).mockRejectedValue(new Error('400 repository already linked to this session'));
    renderPanel();
    await waitFor(() => expect(screen.getByText('Add repository')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Add repository'));
    fireEvent.change(screen.getByLabelText('Repository URL'), {
      target: { value: 'https://github.com/nic/extra' },
    });
    fireEvent.click(screen.getByText('Link'));
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('already linked'));
    // The panel is still visible.
    expect(screen.getByText('Linked repositories')).toBeInTheDocument();
  });

  it('removes a linked repo after confirmation', async () => {
    vi.mocked(api.listSessionRepos)
      .mockResolvedValueOnce([extra]) // initial
      .mockResolvedValueOnce([]); // after remove
    vi.mocked(api.removeSessionRepo).mockResolvedValue(undefined);
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    renderPanel();
    await waitFor(() => expect(screen.getByText('nic/extra')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Remove'));
    await waitFor(() => expect(api.removeSessionRepo).toHaveBeenCalledWith('s1', 'r1'));
    await waitFor(() => expect(screen.queryByText('nic/extra')).not.toBeInTheDocument());
    vi.mocked(window.confirm).mockRestore();
  });
});
