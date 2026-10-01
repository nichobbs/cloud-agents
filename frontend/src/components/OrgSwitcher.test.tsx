import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { Org } from '../lib/orgs';

vi.mock('../context/AuthConfigContext', () => ({
  useAuthConfig: () => ({ configured: false, clientId: '' }),
}));
vi.mock('../context/SessionsContext', () => ({
  useSessions: () => ({ sessions: [] }),
}));

const setActiveOrg = vi.fn();
let orgs: Org[] = [];
vi.mock('../context/OrgContext', () => ({
  useOrgs: () => ({ orgs, personalId: 'personal:gh-1', activeOrgId: 'personal:gh-1', activeOrg: orgs[0], setActiveOrg, reload: vi.fn() }),
}));

import { Nav } from './Nav';

const personal: Org = { id: 'personal:gh-1', name: 'octocat', kind: 'personal', role: 'owner', source: 'native', suspended: false };
const team: Org = { id: 'org-1', name: 'Team', kind: 'native', role: 'member', source: 'native', suspended: false };
const gh: Org = { id: 'org-2', name: 'Acme', kind: 'github_org', role: 'member', source: 'github', suspended: true };

function renderNav() {
  return render(
    <MemoryRouter>
      <Nav />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  localStorage.setItem('cloud_agents_token', 't');
  localStorage.setItem('cloud_agents_login', 'octocat');
  setActiveOrg.mockClear();
});

describe('organisation switcher', () => {
  it('is hidden when the user has only the personal organisation', () => {
    orgs = [personal];
    renderNav();
    expect(screen.queryByLabelText('Organisation')).not.toBeInTheDocument();
  });

  it('lists organisations with kind, selects one, and disables suspended ones with a reason', () => {
    orgs = [personal, team, gh];
    renderNav();
    const select = screen.getByLabelText('Organisation');
    expect(screen.getByRole('option', { name: 'Team (native)' })).toBeEnabled();
    const suspended = screen.getByRole('option', { name: /Acme \(GitHub\)/ });
    expect(suspended).toBeDisabled();
    expect(suspended.textContent).toContain('GitHub membership suspended until you sign in again');
    fireEvent.change(select, { target: { value: 'org-1' } });
    expect(setActiveOrg).toHaveBeenCalledWith('org-1');
  });
});
