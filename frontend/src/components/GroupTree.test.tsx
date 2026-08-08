import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { Session, SessionGroup } from '../types';

vi.mock('../lib/api', () => ({
  api: {
    createGroup: vi.fn(),
    updateGroup: vi.fn(),
    deleteGroup: vi.fn(),
    setSessionGroup: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { GroupTree } from './GroupTree';

const backend: SessionGroup = { id: 'g1', name: 'Backend', parentId: '', createdAt: '0' };
const infra: SessionGroup = { id: 'g2', name: 'Infra', parentId: 'g1', createdAt: '0' };

function session(id: string, over: Partial<Session> = {}): Session {
  return {
    sessionId: id,
    repoUrl: 'https://github.com/nic/app',
    branch: 'main',
    createdAt: '1700000000000',
    ...over,
  };
}

const onGroupsChanged = vi.fn();
const onSessionAssigned = vi.fn();

function renderTree(groups: SessionGroup[], sessions: Session[], filtering = false) {
  return render(
    <MemoryRouter>
      <GroupTree
        groups={groups}
        sessions={sessions}
        filtering={filtering}
        onGroupsChanged={onGroupsChanged}
        onSessionAssigned={onSessionAssigned}
      />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  onGroupsChanged.mockReset();
  onSessionAssigned.mockReset();
  vi.mocked(api.createGroup).mockReset();
  vi.mocked(api.updateGroup).mockReset();
  vi.mocked(api.deleteGroup).mockReset();
  vi.mocked(api.setSessionGroup).mockReset();
});

describe('GroupTree', () => {
  it('renders group rows with a rollup dot and session count, sessions nested', () => {
    renderTree(
      [backend, infra],
      [session('s1', { groupId: 'g1', attention: 'pending' }), session('s2', { groupId: 'g2' })],
    );
    expect(screen.getByRole('button', { name: 'Collapse Backend' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Collapse Infra' })).toBeInTheDocument();
    // Backend's subtree holds both sessions.
    expect(screen.getByText('2')).toBeInTheDocument();
    // The rollup dot carries the worst descendant state (pending).
    expect(screen.getAllByTitle('Attention: Pending').length).toBeGreaterThan(0);
  });

  it('collapses a group on disclosure click and persists the state', () => {
    renderTree([backend], [session('s1', { groupId: 'g1', branch: 'fix-bug' })]);
    expect(screen.getByText('fix-bug')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Collapse Backend' }));
    expect(screen.queryByText('fix-bug')).not.toBeInTheDocument();
    expect(JSON.parse(localStorage.getItem('cloud_agents_tree_collapsed') ?? '[]')).toEqual(['g1']);

    fireEvent.click(screen.getByRole('button', { name: 'Expand Backend' }));
    expect(screen.getByText('fix-bug')).toBeInTheDocument();
    expect(JSON.parse(localStorage.getItem('cloud_agents_tree_collapsed') ?? '[]')).toEqual([]);
  });

  it('creates a root group with Enter in the inline input', async () => {
    vi.mocked(api.createGroup).mockResolvedValue({ id: 'g9', name: 'New', parentId: '', createdAt: '0' });
    renderTree([], []);
    fireEvent.click(screen.getByText('New group'));
    const input = screen.getByLabelText('New group name');
    fireEvent.change(input, { target: { value: 'New' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(api.createGroup).toHaveBeenCalledWith('New', ''));
    await waitFor(() => expect(onGroupsChanged).toHaveBeenCalled());
  });

  it('creates a subgroup with the parent id of the row it was invoked on', async () => {
    vi.mocked(api.createGroup).mockResolvedValue({ id: 'g9', name: 'Sub', parentId: 'g1', createdAt: '0' });
    renderTree([backend], []);
    fireEvent.click(screen.getByRole('button', { name: 'New subgroup in Backend' }));
    const input = screen.getByLabelText('New group name');
    fireEvent.change(input, { target: { value: 'Sub' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(api.createGroup).toHaveBeenCalledWith('Sub', 'g1'));
  });

  it('renames a group keeping its existing parentId', async () => {
    vi.mocked(api.updateGroup).mockResolvedValue({ ...infra, name: 'Platform' });
    renderTree([backend, infra], []);
    fireEvent.click(screen.getByRole('button', { name: 'Rename Infra' }));
    const input = screen.getByLabelText('New name for Infra');
    fireEvent.change(input, { target: { value: 'Platform' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(api.updateGroup).toHaveBeenCalledWith('g2', 'Platform', 'g1'));
    await waitFor(() => expect(onGroupsChanged).toHaveBeenCalled());
  });

  it('deletes a group after confirmation, and not when declined', async () => {
    vi.mocked(api.deleteGroup).mockResolvedValue(undefined);
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
    renderTree([backend], []);
    fireEvent.click(screen.getByRole('button', { name: 'Delete Backend' }));
    expect(api.deleteGroup).not.toHaveBeenCalled();

    confirmSpy.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: 'Delete Backend' }));
    await waitFor(() => expect(api.deleteGroup).toHaveBeenCalledWith('g1'));
    await waitFor(() => expect(onGroupsChanged).toHaveBeenCalled());
    confirmSpy.mockRestore();
  });

  it('assigns a session to a group through the row select', async () => {
    vi.mocked(api.setSessionGroup).mockResolvedValue(undefined);
    renderTree([backend, infra], [session('s1')]);
    const select = screen.getByLabelText('Group for s1');
    // Options: (none) plus the flattened, indented group names.
    expect(select).toHaveDisplayValue('(none)');
    fireEvent.change(select, { target: { value: 'g2' } });
    await waitFor(() => expect(api.setSessionGroup).toHaveBeenCalledWith('s1', 'g2'));
    await waitFor(() => expect(onSessionAssigned).toHaveBeenCalledWith('s1', 'g2'));
  });

  it('surfaces a mutation error inline', async () => {
    vi.mocked(api.createGroup).mockRejectedValue(new Error('400 name required'));
    renderTree([], []);
    fireEvent.click(screen.getByText('New group'));
    const input = screen.getByLabelText('New group name');
    fireEvent.change(input, { target: { value: 'X' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('400'));
    expect(onGroupsChanged).not.toHaveBeenCalled();
  });

  it('hides groups with no matching sessions while filtering', () => {
    renderTree([backend, infra], [session('s1', { groupId: 'g2' })], true);
    // Infra (and its ancestor Backend) hold s1 → both group rows visible.
    expect(screen.getByRole('button', { name: 'Collapse Backend' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Collapse Infra' })).toBeInTheDocument();
  });

  it('prunes an empty group entirely while filtering', () => {
    renderTree([backend], [session('s1')], true);
    // No group row — the name only survives as an option in the assign select.
    expect(screen.queryByRole('button', { name: 'Collapse Backend' })).not.toBeInTheDocument();
  });
});
