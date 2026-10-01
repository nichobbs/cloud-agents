import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import type { Org } from '../lib/orgs';

const reload = vi.fn(async () => undefined);
const setActiveOrg = vi.fn();
let orgs: Org[] = [];
vi.mock('../context/OrgContext', () => ({
  useOrgs: () => ({ orgs, personalId: 'personal:gh-1', activeOrgId: 'personal:gh-1', activeOrg: orgs[0], setActiveOrg, reload }),
}));

const api = vi.hoisted(() => ({
  create: vi.fn(),
  connectGithub: vi.fn(),
  members: vi.fn(),
  setRole: vi.fn(),
  removeMember: vi.fn(),
  invitations: vi.fn(),
  invite: vi.fn(),
  revokeInvitation: vi.fn(),
}));
vi.mock('../lib/orgs', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/orgs')>()),
  orgsApi: api,
}));

import { Organisations } from './Organisations';

const personal: Org = { id: 'personal:gh-1', name: 'octocat', kind: 'personal', role: 'owner', source: 'native', suspended: false };
const team: Org = { id: 'org-1', name: 'Team', kind: 'native', role: 'owner', source: 'native', suspended: false };

beforeEach(() => {
  localStorage.clear();
  localStorage.setItem('cloud_agents_login', 'octocat');
  vi.clearAllMocks();
  orgs = [personal, team];
  api.members.mockResolvedValue([
    { userId: 'gh-1', githubLogin: 'octocat', role: 'owner', source: 'native', suspended: false },
    { userId: 'gh-2', githubLogin: 'hubot', role: 'member', source: 'native', suspended: false },
  ]);
  api.invitations.mockResolvedValue([]);
});

describe('Organisations page', () => {
  it('states the sync delay and that personal organisations have no members', () => {
    orgs = [personal];
    render(<Organisations />);
    expect(screen.getByText(/within an\s+hour/)).toBeInTheDocument();
    expect(screen.getByText(/no members to manage/)).toBeInTheDocument();
  });

  it('creates a native organisation and reloads the list', async () => {
    api.create.mockResolvedValue({ ...team, id: 'org-9', name: 'New Co' });
    render(<Organisations />);
    fireEvent.change(screen.getByLabelText('New organisation name'), { target: { value: ' New Co ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create organisation' }));
    await waitFor(() => expect(api.create).toHaveBeenCalledWith('New Co'));
    await waitFor(() => expect(reload).toHaveBeenCalled());
  });

  it('shows the server error when creation fails', async () => {
    api.create.mockRejectedValue(new Error('name too long'));
    render(<Organisations />);
    fireEvent.change(screen.getByLabelText('New organisation name'), { target: { value: 'x' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create organisation' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('name too long');
  });

  it('invites by login, shows the one-time link, and revokes a pending invitation', async () => {
    api.invite.mockResolvedValue({
      invitation: { id: 'inv-1', githubLogin: 'monalisa', role: 'admin', createdAt: '1', expiresAt: '2' },
      token: 'tok123',
    });
    render(<Organisations />);
    // the team org is the selected detail only after choosing it
    fireEvent.click(screen.getByRole('button', { name: /Team/ }));
    await screen.findByText('hubot');
    fireEvent.change(screen.getByLabelText('GitHub login to invite'), { target: { value: 'monalisa' } });
    fireEvent.change(screen.getByLabelText('Invitation role'), { target: { value: 'admin' } });
    api.invitations.mockResolvedValue([{ id: 'inv-1', githubLogin: 'monalisa', role: 'admin', createdAt: '1', expiresAt: '2' }]);
    fireEvent.click(screen.getByRole('button', { name: 'Invite' }));
    await waitFor(() => expect(api.invite).toHaveBeenCalledWith('org-1', 'monalisa', 'admin'));
    const link = await screen.findByLabelText('Invitation link');
    expect(link).toHaveValue(`${window.location.origin}/invite/tok123`);
    expect(screen.getByText(/shown only once/)).toBeInTheDocument();

    api.revokeInvitation.mockResolvedValue({ ok: true });
    fireEvent.click(await screen.findByRole('button', { name: 'Revoke invitation for monalisa' }));
    await waitFor(() => expect(api.revokeInvitation).toHaveBeenCalledWith('org-1', 'inv-1'));
  });

  it('lets an owner change a role and offers Leave only on the signed-in user', async () => {
    api.setRole.mockResolvedValue({ ok: true });
    render(<Organisations />);
    fireEvent.click(screen.getByRole('button', { name: /Team/ }));
    await screen.findByText('hubot');
    fireEvent.change(screen.getByLabelText('Role of hubot'), { target: { value: 'admin' } });
    await waitFor(() => expect(api.setRole).toHaveBeenCalledWith('org-1', 'gh-2', 'admin'));
    expect(screen.getAllByRole('button', { name: 'Leave' })).toHaveLength(1);
    expect(screen.getByRole('button', { name: 'Remove hubot' })).toBeInTheDocument();
  });

  it('connects a GitHub organisation', async () => {
    api.connectGithub.mockResolvedValue({ ...team, id: 'org-3', kind: 'github_org', source: 'github' });
    render(<Organisations />);
    fireEvent.change(screen.getByLabelText('GitHub organisation login'), { target: { value: 'acme' } });
    fireEvent.click(screen.getByRole('button', { name: 'Connect GitHub organisation' }));
    await waitFor(() => expect(api.connectGithub).toHaveBeenCalledWith('acme'));
  });
});
