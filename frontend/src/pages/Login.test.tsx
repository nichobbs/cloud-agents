import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

// signOut (reached via completeLogin's connection bookkeeping) fires a
// best-effort server-side call through lib/api; mock it so these tests
// never touch the network.
vi.mock('../lib/api', () => ({
  api: { logout: vi.fn().mockResolvedValue(undefined) },
}));

const mockUseAuthConfig = vi.fn();
vi.mock('../context/AuthConfigContext', () => ({
  useAuthConfig: () => mockUseAuthConfig(),
}));

vi.mock('../lib/auth', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/auth')>()),
  beginLogin: vi.fn(),
  setReturnPath: vi.fn(),
}));

import { beginLogin, completeLogin, setReturnPath } from '../lib/auth';
import { Login } from './Login';

function renderLogin(from?: { pathname: string; search: string }) {
  return render(
    <MemoryRouter initialEntries={[{ pathname: '/login', state: from ? { from } : undefined }]}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/sessions" element={<div data-testid="sessions-page" />} />
        <Route path="/prompts" element={<div data-testid="prompts-page" />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  mockUseAuthConfig.mockReset();
  vi.mocked(beginLogin).mockReset();
  vi.mocked(setReturnPath).mockReset();
});

describe('Login', () => {
  it('shows a sign-in button when GitHub OAuth is configured', () => {
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid' });
    renderLogin();
    expect(screen.getByRole('button', { name: 'Sign in with GitHub' })).toBeInTheDocument();
  });

  it('says sign-in is not configured when the deployment has no OAuth app set up', () => {
    mockUseAuthConfig.mockReturnValue({ configured: false, clientId: '' });
    renderLogin();
    expect(screen.getByText(/isn.t configured/)).toBeInTheDocument();
  });

  it('remembers the redirect origin and begins login on click', () => {
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid123' });
    renderLogin({ pathname: '/prompts', search: '' });
    fireEvent.click(screen.getByRole('button', { name: 'Sign in with GitHub' }));
    expect(setReturnPath).toHaveBeenCalledWith('/prompts');
    expect(beginLogin).toHaveBeenCalledWith('cid123');
  });

  it('does not remember a return path when there was no redirect origin', () => {
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid123' });
    renderLogin();
    fireEvent.click(screen.getByRole('button', { name: 'Sign in with GitHub' }));
    expect(setReturnPath).not.toHaveBeenCalled();
    expect(beginLogin).toHaveBeenCalledWith('cid123');
  });

  it('forwards to the redirect origin when already signed in', () => {
    completeLogin('gho_tok', 'octocat');
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid' });
    renderLogin({ pathname: '/prompts', search: '' });
    expect(screen.getByTestId('prompts-page')).toBeInTheDocument();
  });

  it('falls back to /sessions when already signed in with no redirect origin', () => {
    completeLogin('gho_tok', 'octocat');
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid' });
    renderLogin();
    expect(screen.getByTestId('sessions-page')).toBeInTheDocument();
  });
});
