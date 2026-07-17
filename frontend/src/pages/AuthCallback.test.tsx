import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

vi.mock('../lib/api', () => ({
  api: {
    exchangeCode: vi.fn(),
  },
}));

vi.mock('../lib/auth', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/auth')>()),
  completeLogin: vi.fn(),
  takeStoredState: vi.fn(),
}));

import { api } from '../lib/api';
import { completeLogin, takeStoredState } from '../lib/auth';
import { AuthCallback } from './AuthCallback';

function renderCallback(query: string) {
  return render(
    <MemoryRouter initialEntries={[`/auth/callback${query}`]}>
      <Routes>
        <Route path="/auth/callback" element={<AuthCallback />} />
        <Route path="/repos" element={<div data-testid="repos-page" />} />
        <Route path="/sessions" element={<div data-testid="sessions-page" />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.mocked(api.exchangeCode).mockReset();
  vi.mocked(completeLogin).mockReset();
  vi.mocked(takeStoredState).mockReset().mockReturnValue('state123');
});

describe('AuthCallback', () => {
  it('exchanges the code, persists the grant, and lands on the repo browser', async () => {
    vi.mocked(api.exchangeCode).mockResolvedValue({
      token: 'gho_tok',
      login: 'octocat',
      userId: 'gh-42',
    });
    renderCallback('?code=abc123&state=state123');
    await waitFor(() => expect(screen.getByTestId('repos-page')).toBeInTheDocument());
    expect(api.exchangeCode).toHaveBeenCalledWith('abc123');
    expect(completeLogin).toHaveBeenCalledWith('gho_tok', 'octocat');
  });

  it('rejects a state mismatch without calling the server', async () => {
    vi.mocked(takeStoredState).mockReturnValue('expected-state');
    renderCallback('?code=abc123&state=forged-state');
    expect(await screen.findByText(/state mismatch/)).toBeInTheDocument();
    expect(api.exchangeCode).not.toHaveBeenCalled();
    expect(completeLogin).not.toHaveBeenCalled();
  });

  it('surfaces GitHub-reported errors', async () => {
    renderCallback('?error=access_denied&error_description=The+user+denied+access');
    expect(await screen.findByText(/The user denied access/)).toBeInTheDocument();
    expect(api.exchangeCode).not.toHaveBeenCalled();
  });

  it('surfaces exchange failures with a way back', async () => {
    vi.mocked(api.exchangeCode).mockRejectedValue(new Error('400 GitHub rejected the authorization code'));
    renderCallback('?code=abc123&state=state123');
    expect(await screen.findByText(/GitHub rejected the authorization code/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Back to sessions' })).toBeInTheDocument();
    expect(completeLogin).not.toHaveBeenCalled();
  });
});
