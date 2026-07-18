import { describe, it, expect, beforeEach, vi } from 'vitest';

// signOut fires a best-effort server-side logout through lib/api; mock it so
// these tests never touch the network.
vi.mock('./api', () => ({
  api: { logout: vi.fn().mockResolvedValue(undefined) },
}));

import { api } from './api';
import {
  AUTH_CHANGED_EVENT,
  authorizeUrl,
  completeLogin,
  getApiToken,
  getLogin,
  isSignedIn,
  newOAuthState,
  setReturnPath,
  signOut,
  takeReturnPath,
  takeStoredState,
} from './auth';
import { getConnection } from './connections';

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  vi.mocked(api.logout).mockClear();
  vi.mocked(api.logout).mockResolvedValue(undefined);
});

describe('newOAuthState', () => {
  it('produces 32 hex chars, different every time', () => {
    const a = newOAuthState();
    const b = newOAuthState();
    expect(a).toMatch(/^[0-9a-f]{32}$/);
    expect(b).toMatch(/^[0-9a-f]{32}$/);
    expect(a).not.toBe(b);
  });
});

describe('authorizeUrl', () => {
  it('carries client id, callback redirect, scopes, and state', () => {
    const url = new URL(authorizeUrl('cid123', 'state456'));
    expect(url.origin + url.pathname).toBe('https://github.com/login/oauth/authorize');
    expect(url.searchParams.get('client_id')).toBe('cid123');
    expect(url.searchParams.get('redirect_uri')).toBe(`${window.location.origin}/auth/callback`);
    expect(url.searchParams.get('scope')).toBe('repo read:user');
    expect(url.searchParams.get('state')).toBe('state456');
  });
});

describe('takeStoredState', () => {
  it('returns the stored state exactly once', () => {
    sessionStorage.setItem('cloud_agents_oauth_state', 'once');
    expect(takeStoredState()).toBe('once');
    expect(takeStoredState()).toBe('');
  });
});

describe('setReturnPath / takeReturnPath', () => {
  it('returns the stored path exactly once', () => {
    setReturnPath('/prompts');
    expect(takeReturnPath()).toBe('/prompts');
    expect(takeReturnPath()).toBe('');
  });

  it('is empty when nothing was stored', () => {
    expect(takeReturnPath()).toBe('');
  });
});

describe('completeLogin / signOut', () => {
  it('completeLogin stores the bearer, the login, and the GitHub connection', () => {
    completeLogin('gho_tok', 'octocat');
    expect(getApiToken()).toBe('gho_tok');
    expect(getLogin()).toBe('octocat');
    expect(isSignedIn()).toBe(true);
    // The OAuth token doubles as the UI's GitHub connection (repo browser,
    // PR/CI panels light up on sign-in).
    expect(getConnection('github')).toBe('gho_tok');
  });

  it('completeLogin fires AUTH_CHANGED_EVENT so RequireAuth notices without a route change', () => {
    const handler = vi.fn();
    window.addEventListener(AUTH_CHANGED_EVENT, handler);
    completeLogin('gho_tok', 'octocat');
    window.removeEventListener(AUTH_CHANGED_EVENT, handler);
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it('signOut forgets token, login, and connection, and calls the server-side logout', () => {
    completeLogin('gho_tok', 'octocat');
    signOut();
    expect(api.logout).toHaveBeenCalledTimes(1);
    expect(getApiToken()).toBe('');
    expect(getLogin()).toBe('');
    expect(isSignedIn()).toBe(false);
    expect(getConnection('github')).toBe('');
  });

  it('signOut fires AUTH_CHANGED_EVENT so RequireAuth notices without a route change', () => {
    completeLogin('gho_tok', 'octocat');
    const handler = vi.fn();
    window.addEventListener(AUTH_CHANGED_EVENT, handler);
    signOut();
    window.removeEventListener(AUTH_CHANGED_EVENT, handler);
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it('signOut still clears storage when the server-side logout rejects', async () => {
    completeLogin('gho_tok', 'octocat');
    vi.mocked(api.logout).mockRejectedValueOnce(new Error('server unreachable'));
    signOut();
    expect(api.logout).toHaveBeenCalledTimes(1);
    expect(getApiToken()).toBe('');
    expect(getLogin()).toBe('');
    expect(isSignedIn()).toBe(false);
    expect(getConnection('github')).toBe('');
    // Let the swallowed rejection settle so it can't surface as unhandled.
    await Promise.resolve();
  });

  it('is not signed in with only one half present', () => {
    localStorage.setItem('cloud_agents_token', 'static-api-token-only');
    expect(isSignedIn()).toBe(false);
  });
});
