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
///
/// Also covers the profile-attach-failure handoff (#864's core fix): a
/// createSession success followed by a setSessionProfile failure must not
/// orphan the just-created session (a retry from this form would otherwise
/// create a second one) — the session is still tracked and the user still
/// lands on it, with the attach error handed off via router state instead.

const { mockAddSession, mockNavigate } = vi.hoisted(() => ({
  mockAddSession: vi.fn(),
  mockNavigate: vi.fn(),
}));

vi.mock('../lib/api', () => ({
  api: {
    createSession: vi.fn(),
    getProfiles: vi.fn().mockResolvedValue([]),
    setSessionProfile: vi.fn(),
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
  useSessions: () => ({ addSession: mockAddSession }),
}));

vi.mock('react-router-dom', async importOriginal => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => mockNavigate,
}));

import { api } from '../lib/api';
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
  mockAddSession.mockReset();
  mockNavigate.mockReset();
  vi.mocked(api.createSession).mockReset();
  vi.mocked(api.setSessionProfile).mockReset();
  vi.mocked(api.getProfiles).mockReset().mockResolvedValue([]);
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

function makeProfile() {
  return {
    id: 'p1',
    userId: 'u1',
    name: 'sandbox',
    harness: '',
    networkPolicy: 'none' as const,
    credentialMode: 'all' as const,
    credentials: [],
    skillIds: [],
    subagentIds: [],
    mcpServerIds: [],
    toolMode: 'all' as const,
    tools: [],
    createdAt: '0',
    updatedAt: '0',
  };
}

describe('NewSession profile-attach-failure handoff (#864)', () => {
  it('creates the session and navigates with no extra state when no profile is selected', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(null);
    vi.mocked(api.createSession).mockResolvedValue({ sessionId: 's1' });
    renderPage();
    const user = userEvent.setup();

    await user.type(await screen.findByLabelText('Repository URL'), 'https://github.com/owner/repo');
    await user.click(screen.getByRole('button', { name: 'Create session' }));

    await vi.waitFor(() => expect(mockNavigate).toHaveBeenCalledWith('/sessions/s1', undefined));
    expect(mockAddSession).toHaveBeenCalledWith(expect.objectContaining({ sessionId: 's1' }));
    expect(api.setSessionProfile).not.toHaveBeenCalled();
  });

  it('still tracks the session and hands off the error when setSessionProfile fails', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(null);
    vi.mocked(api.getProfiles).mockResolvedValue([makeProfile()]);
    vi.mocked(api.createSession).mockResolvedValue({ sessionId: 's1' });
    vi.mocked(api.setSessionProfile).mockRejectedValue(new Error('profile deleted'));
    renderPage();
    const user = userEvent.setup();

    await user.type(await screen.findByLabelText('Repository URL'), 'https://github.com/owner/repo');
    await user.selectOptions(await screen.findByLabelText('Profile'), 'p1');
    await user.click(screen.getByRole('button', { name: 'Create session' }));

    // The session isn't orphaned: addSession still runs even though the
    // profile attach failed, and the user still lands on the real session
    // (not stuck on the form, which would invite a retry that creates a
    // second session).
    await vi.waitFor(() =>
      expect(mockNavigate).toHaveBeenCalledWith('/sessions/s1', { state: { profileAttachError: 'profile deleted' } }),
    );
    expect(mockAddSession).toHaveBeenCalledWith(expect.objectContaining({ sessionId: 's1' }));
  });
});
