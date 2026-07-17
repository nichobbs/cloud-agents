/// GitHub OAuth login state on this device.
///
/// The OAuth token returned by POST /api/auth/github/exchange becomes the
/// API bearer token (the same localStorage slot the static-token flow uses,
/// so every existing api.ts call picks it up unchanged) and doubles as the
/// GitHub connection powering the repo browser and PR/CI panels.

import { setConnection, clearConnection } from './connections';
import { clearRepoCache } from './github';

const TOKEN_KEY = 'cloud_agents_token';
const LOGIN_KEY = 'cloud_agents_login';
const STATE_KEY = 'cloud_agents_oauth_state';

export function getApiToken(): string {
  return localStorage.getItem(TOKEN_KEY) ?? '';
}

export function getLogin(): string {
  return localStorage.getItem(LOGIN_KEY) ?? '';
}

export function isSignedIn(): boolean {
  return getLogin().length > 0 && getApiToken().length > 0;
}

/** Random URL-safe state for the OAuth round trip (CSRF binding). */
export function newOAuthState(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

/** The GitHub authorize URL for this app. `repo` scope lets the token clone
 *  private repos and drive the PR/CI panels; `read:user` identifies the user. */
export function authorizeUrl(clientId: string, state: string): string {
  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: `${window.location.origin}/auth/callback`,
    scope: 'repo read:user',
    state,
  });
  return `https://github.com/login/oauth/authorize?${params.toString()}`;
}

/** Kick off the login round trip: remember the state, go to GitHub. */
export function beginLogin(clientId: string): void {
  const state = newOAuthState();
  sessionStorage.setItem(STATE_KEY, state);
  window.location.assign(authorizeUrl(clientId, state));
}

/** The state stored when login began ('' if none), cleared on read. */
export function takeStoredState(): string {
  const s = sessionStorage.getItem(STATE_KEY) ?? '';
  sessionStorage.removeItem(STATE_KEY);
  return s;
}

/** Persist a successful exchange: bearer token, display login, and the
 *  GitHub connection for the repo/PR/CI panels (fresh token → fresh caches). */
export function completeLogin(token: string, login: string): void {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(LOGIN_KEY, login);
  setConnection('github', token);
  clearRepoCache();
}

/** Forget everything this device knows about the signed-in user. */
export function signOut(): void {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(LOGIN_KEY);
  clearConnection('github');
  clearRepoCache();
}
