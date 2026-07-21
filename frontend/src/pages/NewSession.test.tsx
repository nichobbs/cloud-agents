import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

/// #599: harness-availability gating (#523) had zero coverage on the pages
/// that surface it. This covers NewSession.tsx's two behaviors: a harness
/// with no runner image on this deployment is offered as a disabled
/// `<option>`, and the submit button itself is disabled when the currently
/// selected harness is one of those unavailable ones — plus the fail-open
/// default (everything enabled) when availability is unknown.

vi.mock('../lib/api', () => ({
  api: {
    createSession: vi.fn(),
    getProfiles: vi.fn().mockResolvedValue([]),
  },
}));

vi.mock('../lib/harnessAvailability', () => ({
  enabledHarnesses: vi.fn(),
}));

vi.mock('../lib/github', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/github')>()),
  isGitHubConnected: vi.fn().mockReturnValue(false),
  listRepos: vi.fn(),
}));

vi.mock('../lib/models', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/models')>()),
  discoverModels: vi.fn(),
}));

vi.mock('../context/SessionsContext', () => ({
  useSessions: () => ({ addSession: vi.fn() }),
}));

import { enabledHarnesses } from '../lib/harnessAvailability';
import { getHarness } from '../lib/harnesses';
import { discoverModels } from '../lib/models';
import { NewSession } from './NewSession';

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/sessions/new']}>
      <NewSession />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.mocked(enabledHarnesses).mockReset();
  vi.mocked(discoverModels)
    .mockReset()
    .mockImplementation(async harnessId => ({ models: getHarness(harnessId).models, source: 'static' }));
});

describe('NewSession harness availability (#523/#599)', () => {
  it('offers a disabled option and a warning hint for a harness with no runner image', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(new Set(['claude']));
    renderPage();

    const codexOption = await screen.findByRole('option', {
      name: 'Codex CLI (not available on this deployment)',
    });
    expect(codexOption).toBeDisabled();

    // The default selected harness (claude) IS available — no warning hint,
    // and the submit button isn't disabled by harness availability.
    expect(screen.queryByText(/no runner image built/)).toBeNull();
    const submit = screen.getByRole('button', { name: 'Create session' });
    expect(submit).toBeDisabled(); // still disabled — repoUrl is empty
  });

  it('disables the submit button when the selected harness has no runner image', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(new Set(['codex'])); // claude (default) NOT in the set
    renderPage();

    await screen.findByText(/no runner image built on this deployment yet/);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Repository URL'), 'https://github.com/owner/repo');

    // Even with a valid repo URL filled in, submit stays disabled because the
    // selected (default) harness isn't available on this deployment.
    expect(screen.getByRole('button', { name: 'Create session' })).toBeDisabled();
  });

  it('fails open — every option enabled and submit ungated — when availability is unknown', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(null);
    renderPage();
    const user = userEvent.setup();

    await user.type(await screen.findByLabelText('Repository URL'), 'https://github.com/owner/repo');

    expect(screen.getByRole('option', { name: 'Codex CLI' })).not.toBeDisabled();
    expect(screen.queryByText(/no runner image built/)).toBeNull();
    expect(screen.getByRole('button', { name: 'Create session' })).not.toBeDisabled();
  });
});
