import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';

vi.mock('../lib/api', () => ({
  api: { getAuthConfig: vi.fn() },
}));

import { api } from '../lib/api';
import { AuthConfigProvider, useAuthConfig } from './AuthConfigContext';

function Consumer() {
  const { configured, clientId } = useAuthConfig();
  return (
    <div data-testid="consumer">
      {configured === null ? 'loading' : configured ? `configured:${clientId}` : 'unconfigured'}
    </div>
  );
}

beforeEach(() => {
  vi.mocked(api.getAuthConfig).mockReset();
});

describe('AuthConfigProvider', () => {
  it('starts in the loading state before the fetch resolves', () => {
    vi.mocked(api.getAuthConfig).mockReturnValue(new Promise(() => {}));
    render(
      <AuthConfigProvider>
        <Consumer />
      </AuthConfigProvider>,
    );
    expect(screen.getByTestId('consumer')).toHaveTextContent('loading');
  });

  it('resolves to the fetched config on success', async () => {
    vi.mocked(api.getAuthConfig).mockResolvedValue({ configured: true, clientId: 'cid123' });
    render(
      <AuthConfigProvider>
        <Consumer />
      </AuthConfigProvider>,
    );
    await waitFor(() =>
      expect(screen.getByTestId('consumer')).toHaveTextContent('configured:cid123'),
    );
  });

  it('falls back to unconfigured on a 404 (older backend without the endpoint)', async () => {
    vi.mocked(api.getAuthConfig).mockRejectedValue(new Error('404 Not Found'));
    render(
      <AuthConfigProvider>
        <Consumer />
      </AuthConfigProvider>,
    );
    await waitFor(() => expect(screen.getByTestId('consumer')).toHaveTextContent('unconfigured'));
  });

  it('stays loading (does not fail open) on a real server error', async () => {
    vi.mocked(api.getAuthConfig).mockRejectedValue(new Error('500 Internal Server Error'));
    render(
      <AuthConfigProvider>
        <Consumer />
      </AuthConfigProvider>,
    );
    // Let the rejection settle, then confirm it did NOT get conflated with
    // "not configured" — that would silently open access on a transient
    // backend problem instead of surfacing it.
    await Promise.resolve();
    await Promise.resolve();
    expect(screen.getByTestId('consumer')).toHaveTextContent('loading');
  });

  it('stays loading (does not fail open) on a network failure with no status', async () => {
    vi.mocked(api.getAuthConfig).mockRejectedValue(new TypeError('Failed to fetch'));
    render(
      <AuthConfigProvider>
        <Consumer />
      </AuthConfigProvider>,
    );
    await Promise.resolve();
    await Promise.resolve();
    expect(screen.getByTestId('consumer')).toHaveTextContent('loading');
  });

  it('does not update state after unmounting mid-fetch', async () => {
    let resolveFetch: (cfg: { configured: boolean; clientId: string }) => void = () => {};
    vi.mocked(api.getAuthConfig).mockReturnValue(
      new Promise(resolve => {
        resolveFetch = resolve;
      }),
    );
    const { unmount } = render(
      <AuthConfigProvider>
        <Consumer />
      </AuthConfigProvider>,
    );
    unmount();

    // Resolving after unmount must not trigger a React "state update on an
    // unmounted component" warning — the provider's active-ref guard exists
    // for exactly this.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    resolveFetch({ configured: true, clientId: 'cid123' });
    await Promise.resolve();
    await Promise.resolve();
    expect(errorSpy).not.toHaveBeenCalled();
    errorSpy.mockRestore();
  });
});
