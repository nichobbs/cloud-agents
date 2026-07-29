/// GitHub OAuth login state on this device.
///
/// The OAuth token returned by POST /api/auth/github/exchange becomes the
/// API bearer token (the same localStorage slot the static-token flow uses,
/// so every existing api.ts call picks it up unchanged) and doubles as the
/// GitHub connection powering the repo browser and PR/CI panels.

import { api } from './api';
import { setConnection, clearConnection } from './connections';
import { clearRepoCache } from './github';

const TOKEN_KEY = 'cloud_agents_token';
const LOGIN_KEY = 'cloud_agents_login';
const STATE_KEY = 'cloud_agents_oauth_state';
const RETURN_TO_KEY = 'cloud_agents_oauth_return_to';

/** Fired after completeLogin()/signOut() change sign-in state, so listeners
 *  that aren't themselves triggering the change (e.g. RequireAuth guarding
 *  a different render than the one showing the sign-out button) notice
 *  immediately rather than waiting for the next route change. */
export const AUTH_CHANGED_EVENT = 'cloud-agents-auth-changed';

function notifyAuthChanged(): void {
  window.dispatchEvent(new Event(AUTH_CHANGED_EVENT));
}

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

/** Remember the page RequireAuth redirected from, so AuthCallback can send
 *  the user back there instead of always landing on /repos. */
export function setReturnPath(path: string): void {
  sessionStorage.setItem(RETURN_TO_KEY, path);
}

/** The path stored before login began ('' if none — e.g. sign-in was
 *  triggered from the nav bar rather than a RequireAuth redirect), cleared
 *  on read. */
export function takeReturnPath(): string {
  const p = sessionStorage.getItem(RETURN_TO_KEY) ?? '';
  sessionStorage.removeItem(RETURN_TO_KEY);
  return p;
}

/** Persist a successful exchange: bearer token, display login, and the
 *  GitHub connection for the repo/PR/CI panels (fresh token → fresh caches). */
export function completeLogin(token: string, login: string): void {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(LOGIN_KEY, login);
  setConnection('github', token);
  clearRepoCache();
  notifyAuthChanged();
}

/** Forget everything this device knows about the signed-in user, and ask the
 *  server (best-effort) to drop the token's validation-cache row so its next
 *  presentation must revalidate live. The server call fires FIRST — while the
 *  token is still in storage for authHeaders() — but the local forget is
 *  synchronous and unconditional: a failed or slow server round trip never
 *  blocks or cancels signing out on this device. */
export function signOut(): void {
  void api.logout().catch(() => {
    /* best-effort — the device forgets the token regardless */
  });
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(LOGIN_KEY);
  clearConnection('github');
  clearRepoCache();
  notifyAuthChanged();
}
