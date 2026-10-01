import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

/// #599: harness-availability gating (#523) had zero coverage on the pages
/// that surface it. This covers Profiles.tsx's profile-form harness selector:
/// a harness with no runner image on this deployment is offered as a disabled
/// `<option>`, and every option is enabled when availability is unknown
/// (fail-open) — same convention as NewSession.tsx's harness picker.
///
/// It also covers per-profile tool enablement (#614/#615/#616): the form sends
/// toolMode/tools on every save (never relying on the backend's back-compat
/// patchMissingToolFields, which would normalize an absent toolMode to 'all'
/// and silently drop a 'selected' profile's allowlist), and a 'selected' mode
/// with zero tools is rejected client-side, mirroring the backend's own rule.

vi.mock('../lib/api', () => ({
  api: {
    getProfiles: vi.fn(),
    getCredentialNames: vi.fn(),
    getSkills: vi.fn(),
    getSubagents: vi.fn(),
    getMcpServers: vi.fn(),
    addProfile: vi.fn(),
    updateProfile: vi.fn(),
    deleteProfile: vi.fn(),
    getObserverSettings: vi.fn(),
    saveObserverSettings: vi.fn(),
  },
}));

vi.mock('../lib/harnessAvailability', () => ({
  enabledHarnesses: vi.fn(),
}));

import { api } from '../lib/api';
import { enabledHarnesses } from '../lib/harnessAvailability';
import { Profiles } from './Profiles';
import type { Profile } from '../types';

const DISABLED_OBSERVER = {
  enabled: 'false',
  harness: 'claude',
  model: '',
  repoAccess: 'diff',
  midRunMinutes: '15',
  maxPassesPerDay: '48',
};

const EXISTING_PROFILE: Profile = {
  id: 'p9',
  userId: 'u1',
  name: 'prod',
  harness: 'claude',
  networkPolicy: 'full',
  credentialMode: 'all',
  credentials: [],
  skillIds: [],
  subagentIds: [],
  mcpServerIds: [],
  toolMode: 'all',
  tools: [],
  createdAt: '0',
  updatedAt: '0',
};

beforeEach(() => {
  vi.mocked(api.getProfiles).mockReset().mockResolvedValue([]);
  vi.mocked(api.getCredentialNames).mockReset().mockResolvedValue([]);
  vi.mocked(api.getSkills).mockReset().mockResolvedValue([]);
  vi.mocked(api.getSubagents).mockReset().mockResolvedValue([]);
  vi.mocked(api.getMcpServers).mockReset().mockResolvedValue([]);
  vi.mocked(api.addProfile).mockReset().mockResolvedValue({
    id: 'p1',
    userId: 'u1',
    name: 'x',
    harness: '',
    networkPolicy: 'full',
    credentialMode: 'all',
    credentials: [],
    skillIds: [],
    subagentIds: [],
    mcpServerIds: [],
    toolMode: 'all',
    tools: [],
    createdAt: '0',
    updatedAt: '0',
  });
  vi.mocked(api.updateProfile).mockReset();
  vi.mocked(api.deleteProfile).mockReset();
  vi.mocked(api.getObserverSettings).mockReset().mockResolvedValue({ ...DISABLED_OBSERVER });
  vi.mocked(api.saveObserverSettings).mockReset().mockImplementation(async (_id, o) => o);
  vi.mocked(enabledHarnesses).mockReset().mockResolvedValue(null);
});

describe('Profiles harness availability (#523/#599)', () => {
  it('disables an unavailable harness option in the profile-form selector', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(new Set(['claude']));
    render(<Profiles />);

    const codexOption = await screen.findByRole('option', {
      name: 'codex (not built on this deployment)',
    });
    expect(codexOption).toBeDisabled();

    const claudeOption = screen.getByRole('option', { name: 'claude' });
    expect(claudeOption).not.toBeDisabled();
  });

  it('enables every harness option (incl. gemini and antigravity) when availability is unknown (fail-open)', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(null);
    render(<Profiles />);

    await screen.findByText('No profiles yet — create one above.');
    for (const id of ['claude', 'codex', 'opencode', 'gemini', 'antigravity']) {
      expect(screen.getByRole('option', { name: id })).not.toBeDisabled();
    }
  });
});

describe('Profiles tool enablement (#614/#615/#616)', () => {
  it("sends toolMode 'all' with an empty tools list by default", async () => {
    const user = userEvent.setup();
    render(<Profiles />);
    await screen.findByText('No profiles yet — create one above.');

    await user.type(screen.getByLabelText('Profile name'), 'default-profile');
    await user.click(screen.getByRole('button', { name: 'Create profile' }));

    expect(api.addProfile).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'default-profile', toolMode: 'all', tools: [] }),
    );
  });

  it('rejects a selected-mode profile with no tools, client-side, before any save', async () => {
    const user = userEvent.setup();
    render(<Profiles />);
    await screen.findByText('No profiles yet — create one above.');

    await user.type(screen.getByLabelText('Profile name'), 'locked-down');
    await user.selectOptions(screen.getByLabelText('Callback tools mode'), 'selected');
    await user.click(screen.getByRole('button', { name: 'Create profile' }));

    expect(api.addProfile).not.toHaveBeenCalled();
    expect(
      screen.getByText(
        "Selected-tool mode requires at least one tool — or switch to 'All tools'.",
      ),
    ).toBeInTheDocument();
  });

  it('sends the selected tool names when toolMode is selected', async () => {
    const user = userEvent.setup();
    render(<Profiles />);
    await screen.findByText('No profiles yet — create one above.');

    await user.type(screen.getByLabelText('Profile name'), 'scoped');
    await user.selectOptions(screen.getByLabelText('Callback tools mode'), 'selected');
    await user.click(screen.getByRole('checkbox', { name: 'remember' }));
    await user.click(screen.getByRole('checkbox', { name: 'recall' }));
    await user.click(screen.getByRole('button', { name: 'Create profile' }));

    expect(api.addProfile).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'scoped', toolMode: 'selected', tools: ['remember', 'recall'] }),
    );
  });
});

describe('Profiles observer settings', () => {
  it('saves default (disabled) observer settings for a new profile after it is created', async () => {
    const user = userEvent.setup();
    render(<Profiles />);
    await screen.findByText('No profiles yet — create one above.');

    await user.type(screen.getByLabelText('Profile name'), 'fresh');
    await user.click(screen.getByRole('button', { name: 'Create profile' }));

    await waitFor(() => expect(api.saveObserverSettings).toHaveBeenCalledWith('p1', DISABLED_OBSERVER));
    expect(vi.mocked(api.addProfile).mock.invocationCallOrder[0]!).toBeLessThan(
      vi.mocked(api.saveObserverSettings).mock.invocationCallOrder[0]!,
    );
  });

  it('hides the observer options until enabled, then saves the chosen ones', async () => {
    const user = userEvent.setup();
    render(<Profiles />);
    await screen.findByText('No profiles yet — create one above.');
    expect(screen.queryByLabelText('Max passes per day')).not.toBeInTheDocument();

    await user.type(screen.getByLabelText('Profile name'), 'watched');
    await user.click(screen.getByRole('checkbox', { name: 'Observe sessions using this profile' }));
    await user.selectOptions(screen.getByLabelText('Observer harness'), 'codex');
    await user.type(screen.getByLabelText('Observer model'), 'gpt-x');
    await user.selectOptions(screen.getByLabelText('Repo access'), 'workspace');
    await user.selectOptions(screen.getByLabelText('Mid-run passes'), '0');
    await user.clear(screen.getByLabelText('Max passes per day'));
    await user.type(screen.getByLabelText('Max passes per day'), '10');
    await user.click(screen.getByRole('button', { name: 'Create profile' }));

    await waitFor(() =>
      expect(api.saveObserverSettings).toHaveBeenCalledWith('p1', {
        enabled: 'true',
        harness: 'codex',
        model: 'gpt-x',
        repoAccess: 'workspace',
        midRunMinutes: '0',
        maxPassesPerDay: '10',
      }),
    );
  });

  it('loads the observer settings of an existing profile and saves them after the profile update', async () => {
    const user = userEvent.setup();
    vi.mocked(api.getProfiles).mockResolvedValue([EXISTING_PROFILE]);
    vi.mocked(api.updateProfile).mockResolvedValue(EXISTING_PROFILE);
    vi.mocked(api.getObserverSettings).mockResolvedValue({
      enabled: 'true',
      harness: 'gemini',
      model: 'flash',
      repoAccess: 'none',
      midRunMinutes: '30',
      maxPassesPerDay: '20',
    });
    render(<Profiles />);
    await user.click(await screen.findByRole('button', { name: 'Edit prod' }));

    expect(api.getObserverSettings).toHaveBeenCalledWith('p9');
    expect(await screen.findByLabelText('Observer model')).toHaveValue('flash');
    expect(screen.getByLabelText('Observer harness')).toHaveValue('gemini');
    expect(screen.getByLabelText('Repo access')).toHaveValue('none');
    expect(screen.getByLabelText('Mid-run passes')).toHaveValue('30');
    expect(screen.getByLabelText('Max passes per day')).toHaveValue(20);

    await user.click(screen.getByRole('button', { name: 'Update profile' }));
    await waitFor(() =>
      expect(api.saveObserverSettings).toHaveBeenCalledWith(
        'p9',
        expect.objectContaining({ enabled: 'true', harness: 'gemini', model: 'flash' }),
      ),
    );
    expect(vi.mocked(api.updateProfile).mock.invocationCallOrder[0]!).toBeLessThan(
      vi.mocked(api.saveObserverSettings).mock.invocationCallOrder[0]!,
    );
  });

  it('shows an observer save error and stays on the saved profile', async () => {
    const user = userEvent.setup();
    vi.mocked(api.saveObserverSettings).mockRejectedValue(new Error('maxPassesPerDay must be between 1 and 500'));
    render(<Profiles />);
    await screen.findByText('No profiles yet — create one above.');
    await user.type(screen.getByLabelText('Profile name'), 'bad');
    await user.click(screen.getByRole('button', { name: 'Create profile' }));

    expect(await screen.findByText('maxPassesPerDay must be between 1 and 500')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Update profile' })).toBeInTheDocument();
  });
});
