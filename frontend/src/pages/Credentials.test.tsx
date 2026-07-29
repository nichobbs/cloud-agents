import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

vi.mock('../lib/api', () => ({
  api: {
    getCredentialNames: vi.fn(),
    putCredential: vi.fn(),
    deleteCredential: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { Credentials } from './Credentials';

beforeEach(() => {
  vi.mocked(api.getCredentialNames).mockReset();
});

describe('Credentials', () => {
  it('shows the stored credentials once loaded', async () => {
    vi.mocked(api.getCredentialNames).mockResolvedValue([
      { name: 'GITHUB_TOKEN', updatedAt: '0' },
    ]);
    render(<MemoryRouter><Credentials /></MemoryRouter>);
    expect(await screen.findByText('GITHUB_TOKEN')).toBeInTheDocument();
  });

  // #503: /api/credentials always 401s with AuthNotConfigured when no
  // static token is set, unlike every other RequireAuth-guarded route,
  // which falls back to open access when auth isn't configured at all.
  // This page must surface that as a clear "not available" state instead
  // of a raw fetch-error banner.
  it('shows a friendly unavailable message instead of a raw error on AuthNotConfigured', async () => {
    vi.mocked(api.getCredentialNames).mockRejectedValue(
      new Error('401 {"error":"authentication is not configured; access is disabled"}'),
    );
    render(<MemoryRouter><Credentials /></MemoryRouter>);
    expect(await screen.findByText(/isn't available on this deployment/i)).toBeInTheDocument();
    expect(screen.queryByLabelText('Credential name')).not.toBeInTheDocument();
  });

  it('shows the generic error banner for a different failure', async () => {
    vi.mocked(api.getCredentialNames).mockRejectedValue(new Error('500 boom'));
    render(<MemoryRouter><Credentials /></MemoryRouter>);
    expect(await screen.findByText('500 boom')).toBeInTheDocument();
    expect(screen.getByLabelText('Credential name')).toBeInTheDocument();
  });

  // #571: the detector now parses the `{"error": "..."}` body and compares
  // the `error` field for exact equality, rather than testing whether the
  // raw message merely *contains* the AuthNotConfigured text. A 401 whose
  // body just happens to mention the phrase in passing (not the literal
  // AuthNotConfigured shape) must NOT be treated as "auth not configured" —
  // the old substring check would have false-positived on this.
  it('does not treat a 401 that merely mentions the phrase in passing as AuthNotConfigured', async () => {
    vi.mocked(api.getCredentialNames).mockRejectedValue(
      new Error(
        '401 {"error":"forbidden: note that authentication is not configured; access is disabled for other users"}',
      ),
    );
    render(<MemoryRouter><Credentials /></MemoryRouter>);
    expect(
      await screen.findByText(
        '401 {"error":"forbidden: note that authentication is not configured; access is disabled for other users"}',
      ),
    ).toBeInTheDocument();
    expect(screen.getByLabelText('Credential name')).toBeInTheDocument();
  });

  it('does not treat a non-JSON 401 body as AuthNotConfigured', async () => {
    vi.mocked(api.getCredentialNames).mockRejectedValue(new Error('401 unauthorized'));
    render(<MemoryRouter><Credentials /></MemoryRouter>);
    expect(await screen.findByText('401 unauthorized')).toBeInTheDocument();
    expect(screen.getByLabelText('Credential name')).toBeInTheDocument();
  });
});
