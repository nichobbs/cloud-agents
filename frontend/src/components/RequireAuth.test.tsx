import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

// signOut fires a best-effort server-side logout through lib/api; mock it so
// these tests never touch the network.
vi.mock('../lib/api', () => ({
  api: { logout: vi.fn().mockResolvedValue(undefined) },
}));

const mockUseAuthConfig = vi.fn();
vi.mock('../context/AuthConfigContext', () => ({
  useAuthConfig: () => mockUseAuthConfig(),
}));

import { completeLogin, signOut } from '../lib/auth';
import { RequireAuth } from './RequireAuth';

function renderGuarded() {
  return render(
    <MemoryRouter initialEntries={['/sessions']}>
      <Routes>
        <Route
          path="/sessions"
          element={
            <RequireAuth>
              <div data-testid="protected-page">secret</div>
            </RequireAuth>
          }
        />
        <Route path="/login" element={<div data-testid="login-page">login</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  mockUseAuthConfig.mockReset();
});

describe('RequireAuth', () => {
  it('renders nothing while auth config is still loading', () => {
    mockUseAuthConfig.mockReturnValue({ configured: null, clientId: '' });
    const { container } = renderGuarded();
    expect(container).toBeEmptyDOMElement();
  });

  it('renders children when sign-in is not configured on this deployment', () => {
    mockUseAuthConfig.mockReturnValue({ configured: false, clientId: '' });
    renderGuarded();
    expect(screen.getByTestId('protected-page')).toBeInTheDocument();
  });

  it('redirects to /login when configured and not signed in', () => {
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid' });
    renderGuarded();
    expect(screen.getByTestId('login-page')).toBeInTheDocument();
    expect(screen.queryByTestId('protected-page')).not.toBeInTheDocument();
  });

  it('renders children when configured and signed in', () => {
    completeLogin('gho_tok', 'octocat');
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid' });
    renderGuarded();
    expect(screen.getByTestId('protected-page')).toBeInTheDocument();
  });

  it('redirects immediately on sign-out, without waiting for a route change', async () => {
    completeLogin('gho_tok', 'octocat');
    mockUseAuthConfig.mockReturnValue({ configured: true, clientId: 'cid' });
    renderGuarded();
    expect(screen.getByTestId('protected-page')).toBeInTheDocument();

    signOut();

    await waitFor(() => expect(screen.getByTestId('login-page')).toBeInTheDocument());
  });
});
