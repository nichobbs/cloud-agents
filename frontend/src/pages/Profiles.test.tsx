import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';

/// #599: harness-availability gating (#523) had zero coverage on the pages
/// that surface it. This covers Profiles.tsx's profile-form harness selector:
/// a harness with no runner image on this deployment is offered as a disabled
/// `<option>`, and every option is enabled when availability is unknown
/// (fail-open) — same convention as NewSession.tsx's harness picker.

vi.mock('../lib/api', () => ({
  api: {
    getProfiles: vi.fn(),
    getCredentialNames: vi.fn(),
    getSkills: vi.fn(),
    getSubagents: vi.fn(),
    getMcpServers: vi.fn(),
  },
}));

vi.mock('../lib/harnessAvailability', () => ({
  enabledHarnesses: vi.fn(),
}));

import { api } from '../lib/api';
import { enabledHarnesses } from '../lib/harnessAvailability';
import { Profiles } from './Profiles';

beforeEach(() => {
  vi.mocked(api.getProfiles).mockReset().mockResolvedValue([]);
  vi.mocked(api.getCredentialNames).mockReset().mockResolvedValue([]);
  vi.mocked(api.getSkills).mockReset().mockResolvedValue([]);
  vi.mocked(api.getSubagents).mockReset().mockResolvedValue([]);
  vi.mocked(api.getMcpServers).mockReset().mockResolvedValue([]);
  vi.mocked(enabledHarnesses).mockReset();
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

  it('enables every harness option when availability is unknown (fail-open)', async () => {
    vi.mocked(enabledHarnesses).mockResolvedValue(null);
    render(<Profiles />);

    await screen.findByText('No profiles yet — create one above.');
    for (const id of ['claude', 'codex', 'opencode']) {
      expect(screen.getByRole('option', { name: id })).not.toBeDisabled();
    }
  });
});
