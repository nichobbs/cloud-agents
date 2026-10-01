import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const reload = vi.fn(async () => undefined);
const setActiveOrg = vi.fn();
vi.mock('../context/OrgContext', () => ({
  useOrgs: () => ({ orgs: [], personalId: '', activeOrgId: '', activeOrg: undefined, setActiveOrg, reload }),
}));

const accept = vi.hoisted(() => vi.fn());
vi.mock('../lib/orgs', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/orgs')>()),
  orgsApi: { acceptInvitation: accept },
}));

import { AcceptInvitation } from './AcceptInvitation';

function renderAt() {
  return render(
    <MemoryRouter initialEntries={['/invite/tok123']}>
      <Routes>
        <Route path="/invite/:token" element={<AcceptInvitation />} />
        <Route path="/orgs" element={<div>settings page</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('AcceptInvitation', () => {
  it('accepts the token, switches to the new org and opens settings', async () => {
    accept.mockResolvedValue({ id: 'org-1', name: 'Team', kind: 'native', role: 'member', source: 'native', suspended: false });
    renderAt();
    expect(await screen.findByText('settings page')).toBeInTheDocument();
    expect(accept).toHaveBeenCalledTimes(1);
    expect(accept).toHaveBeenCalledWith('tok123');
    expect(setActiveOrg).toHaveBeenCalledWith('org-1');
  });

  it('shows the server error and does not switch', async () => {
    accept.mockRejectedValue(new Error('invitation is for a different GitHub login'));
    renderAt();
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('different GitHub login'));
    expect(setActiveOrg).not.toHaveBeenCalled();
  });
});
