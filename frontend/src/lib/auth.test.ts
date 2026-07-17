import { describe, it, expect, beforeEach } from 'vitest';
import {
  authorizeUrl,
  completeLogin,
  getApiToken,
  getLogin,
  isSignedIn,
  newOAuthState,
  signOut,
  takeStoredState,
} from './auth';
import { getConnection } from './connections';

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
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

  it('signOut forgets token, login, and connection', () => {
    completeLogin('gho_tok', 'octocat');
    signOut();
    expect(getApiToken()).toBe('');
    expect(getLogin()).toBe('');
    expect(isSignedIn()).toBe(false);
    expect(getConnection('github')).toBe('');
  });

  it('is not signed in with only one half present', () => {
    localStorage.setItem('cloud_agents_token', 'static-api-token-only');
    expect(isSignedIn()).toBe(false);
  });
});
