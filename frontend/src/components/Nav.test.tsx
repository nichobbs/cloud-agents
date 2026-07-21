import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

const mockUseAuthConfig = vi.fn();
vi.mock('../context/AuthConfigContext', () => ({
  useAuthConfig: () => mockUseAuthConfig(),
}));

vi.mock('../lib/auth', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/auth')>()),
  beginLogin: vi.fn(),
}));

import { Nav } from './Nav';

function renderNav(path = '/sessions') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Nav />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  mockUseAuthConfig.mockReturnValue({ configured: false, clientId: '' });
});

describe('Nav', () => {
  it('renders every nav link and the toggle button', () => {
    renderNav();
    for (const label of ['Sessions', 'Repos', 'Prompts', 'Profiles', 'Library', 'Credentials', 'Integrations', 'Webhooks']) {
      expect(screen.getByRole('link', { name: label })).toBeInTheDocument();
    }
    expect(screen.getByRole('button', { name: 'Toggle navigation menu' })).toBeInTheDocument();
  });

  it('the link panel starts closed and opens on toggle click (mobile collapse state)', () => {
    renderNav();
    const toggle = screen.getByRole('button', { name: 'Toggle navigation menu' });
    const panel = screen.getByRole('link', { name: 'Sessions' }).parentElement;
    expect(toggle).toHaveAttribute('aria-expanded', 'false');
    expect(panel?.className).not.toContain('nav-links--open');

    fireEvent.click(toggle);
    expect(toggle).toHaveAttribute('aria-expanded', 'true');
    expect(panel?.className).toContain('nav-links--open');

    fireEvent.click(toggle);
    expect(toggle).toHaveAttribute('aria-expanded', 'false');
    expect(panel?.className).not.toContain('nav-links--open');
  });

  it('closes the menu when a route change happens', () => {
    renderNav();
    const toggle = screen.getByRole('button', { name: 'Toggle navigation menu' });
    fireEvent.click(toggle);
    expect(toggle).toHaveAttribute('aria-expanded', 'true');

    fireEvent.click(screen.getByRole('link', { name: 'Repos' }));
    expect(toggle).toHaveAttribute('aria-expanded', 'false');
  });
});
