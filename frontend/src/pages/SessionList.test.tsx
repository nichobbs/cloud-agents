import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { Session, SessionGroup } from '../types';

vi.mock('../lib/api', () => ({
  api: {
    listGroups: vi.fn(),
    createGroup: vi.fn(),
    updateGroup: vi.fn(),
    deleteGroup: vi.fn(),
    setSessionGroup: vi.fn(),
  },
}));

const mockUpdateSession = vi.fn();
let mockSessions: Session[] = [];
vi.mock('../context/SessionsContext', () => ({
  useSessions: () => ({ sessions: mockSessions, updateSession: mockUpdateSession }),
}));

import { api } from '../lib/api';
import { SessionList } from './SessionList';

function session(id: string, over: Partial<Session> = {}): Session {
  return {
    sessionId: id,
    repoUrl: 'https://github.com/nic/app',
    branch: 'main',
    createdAt: '1700000000000',
    ...over,
  };
}

const working = session('s-work', { branch: 'feat-x', status: 'RUNNING', attention: 'working' });
const pending = session('s-pend', { branch: 'fix-bug', attention: 'pending' });
const viewed = session('s-view', { branch: 'docs', attention: 'viewed' });

function renderList(path = '/sessions') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <SessionList />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  mockSessions = [working, pending, viewed];
  mockUpdateSession.mockReset();
  vi.mocked(api.listGroups).mockReset();
  vi.mocked(api.listGroups).mockResolvedValue([]);
});

describe('SessionList', () => {
  it('shows attention chips with live counts for the visible tab', async () => {
    renderList();
    await waitFor(() => expect(api.listGroups).toHaveBeenCalled());
    expect(screen.getByRole('button', { name: 'All (3)' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Working (1)' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Pending (1)' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Viewed (1)' })).toBeInTheDocument();
  });

  it('filters the list when a chip is clicked', async () => {
    renderList();
    await waitFor(() => expect(screen.getByText('fix-bug')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: 'Pending (1)' }));
    expect(screen.getByText('fix-bug')).toBeInTheDocument();
    expect(screen.queryByText('feat-x')).not.toBeInTheDocument();
    expect(screen.queryByText('docs')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Pending (1)' })).toHaveAttribute('aria-pressed', 'true');
    // Back to All restores everything.
    fireEvent.click(screen.getByRole('button', { name: 'All (3)' }));
    expect(screen.getByText('feat-x')).toBeInTheDocument();
  });

  it('preselects the Pending chip from ?filter=pending', async () => {
    renderList('/sessions?filter=pending');
    await waitFor(() => expect(api.listGroups).toHaveBeenCalled());
    expect(screen.getByRole('button', { name: 'Pending (1)' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByText('fix-bug')).toBeInTheDocument();
    expect(screen.queryByText('feat-x')).not.toBeInTheDocument();
  });

  it('ignores an unknown filter param value', async () => {
    renderList('/sessions?filter=bogus');
    await waitFor(() => expect(api.listGroups).toHaveBeenCalled());
    expect(screen.getByRole('button', { name: 'All (3)' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByText('feat-x')).toBeInTheDocument();
  });

  it('filters by text against repo, branch, and harness', async () => {
    renderList();
    await waitFor(() => expect(screen.getByText('fix-bug')).toBeInTheDocument());
    fireEvent.change(screen.getByPlaceholderText('Filter sessions…'), {
      target: { value: 'fix-bug' },
    });
    expect(screen.getByText('fix-bug')).toBeInTheDocument();
    expect(screen.queryByText('feat-x')).not.toBeInTheDocument();
    expect(screen.queryByText('docs')).not.toBeInTheDocument();
  });

  it('renders the group tree when the backend has groups', async () => {
    const g: SessionGroup = { id: 'g1', name: 'Backend', parentId: '', createdAt: '0' };
    vi.mocked(api.listGroups).mockResolvedValue([g]);
    mockSessions = [session('s-grouped', { branch: 'grouped-branch', groupId: 'g1' })];
    renderList();
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Collapse Backend' })).toBeInTheDocument(),
    );
    expect(screen.getByText('grouped-branch')).toBeInTheDocument();
    expect(screen.getByText('New group')).toBeInTheDocument();
  });

  it('hides all grouping UI when listGroups fails (older backend) but chips still work', async () => {
    vi.mocked(api.listGroups).mockRejectedValue(new Error('404 not found'));
    renderList();
    await waitFor(() => expect(api.listGroups).toHaveBeenCalled());
    expect(screen.queryByText('New group')).not.toBeInTheDocument();
    // Flat cards (full variant shows the session id line).
    expect(screen.getByText('s-work')).toBeInTheDocument();
    // Chips still filter via the client-side attention fallback.
    fireEvent.click(screen.getByRole('button', { name: 'Working (1)' }));
    expect(screen.getByText('feat-x')).toBeInTheDocument();
    expect(screen.queryByText('fix-bug')).not.toBeInTheDocument();
  });

  it('shows a filtered-empty message when nothing matches', async () => {
    mockSessions = [viewed];
    renderList('/sessions?filter=working');
    await waitFor(() => expect(api.listGroups).toHaveBeenCalled());
    expect(screen.getByText('No sessions match the current filters.')).toBeInTheDocument();
  });

  it('keeps the archived tab working alongside the chips', async () => {
    mockSessions = [working, session('s-arch', { branch: 'old-work', isArchived: '1', attention: 'viewed' })];
    renderList();
    await waitFor(() => expect(api.listGroups).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: 'Archived (1)' }));
    expect(screen.getByText('old-work')).toBeInTheDocument();
    expect(screen.queryByText('feat-x')).not.toBeInTheDocument();
    // Counts follow the visible tab.
    expect(screen.getByRole('button', { name: 'Viewed (1)' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Working (0)' })).toBeInTheDocument();
  });
});
