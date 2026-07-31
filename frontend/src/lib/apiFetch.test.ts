import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { apiFetch } from './api';
import { completeLogin, getApiToken, isSignedIn, takeReturnPath } from './auth';

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('apiFetch 401 handling', () => {
  it('retries request with fresh token when refreshToken succeeds on 401', async () => {
    completeLogin('gho_old', 'octocat');

    const fetchMock = vi.fn()
      // First call (listSessions): 401
      .mockResolvedValueOnce(new Response('401 unauthorized', { status: 401 }))
      // Second call (refreshToken POST /api/auth/github/refresh): 200 with new token
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'gho_new', login: 'octocat', userId: 'gh-1' }), { status: 200 }))
      // Third call (retried listSessions): 200
      .mockResolvedValueOnce(new Response(JSON.stringify({ sessions: [] }), { status: 200 }));

    vi.stubGlobal('fetch', fetchMock);

    const res = await apiFetch('/api/sessions', { headers: { Authorization: 'Bearer gho_old' } });
    expect(res.status).toBe(200);
    expect(getApiToken()).toBe('gho_new');
  });

  it('signs out and saves return path when refreshToken fails on 401', async () => {
    completeLogin('gho_old', 'octocat');

    const fetchMock = vi.fn()
      // First call: 401
      .mockResolvedValueOnce(new Response('401 unauthorized', { status: 401 }))
      // Second call (refreshToken): 401
      .mockResolvedValueOnce(new Response('401 unauthorized', { status: 401 }));

    vi.stubGlobal('fetch', fetchMock);

    const res = await apiFetch('/api/sessions', { headers: { Authorization: 'Bearer gho_old' } });
    expect(res.status).toBe(401);
    expect(isSignedIn()).toBe(false);
    expect(takeReturnPath()).toBe(window.location.pathname + window.location.search);
  });

  it('queues concurrent 401 requests behind a single refresh and retries all with fresh token', async () => {
    completeLogin('gho_old', 'octocat');

    let refreshCalls = 0;
    let sessionsAttempt = 0;
    let promptsAttempt = 0;

    const fetchMock = vi.fn().mockImplementation((input: string) => {
      if (input.includes('/api/auth/github/refresh')) {
        refreshCalls++;
        return Promise.resolve(new Response(JSON.stringify({ token: 'gho_new', login: 'octocat', userId: 'gh-1' }), { status: 200 }));
      }
      if (input.includes('/api/sessions')) {
        sessionsAttempt++;
        if (sessionsAttempt === 1) return Promise.resolve(new Response('401 unauthorized', { status: 401 }));
        return Promise.resolve(new Response(JSON.stringify({ sessions: [] }), { status: 200 }));
      }
      if (input.includes('/api/prompts')) {
        promptsAttempt++;
        if (promptsAttempt === 1) return Promise.resolve(new Response('401 unauthorized', { status: 401 }));
        return Promise.resolve(new Response(JSON.stringify({ prompts: [] }), { status: 200 }));
      }
      return Promise.resolve(new Response('404 not found', { status: 404 }));
    });

    vi.stubGlobal('fetch', fetchMock);

    const [res1, res2] = await Promise.all([
      apiFetch('/api/sessions', { headers: { Authorization: 'Bearer gho_old' } }),
      apiFetch('/api/prompts', { headers: { Authorization: 'Bearer gho_old' } }),
    ]);

    expect(res1.status).toBe(200);
    expect(res2.status).toBe(200);
    expect(refreshCalls).toBe(1);
    expect(getApiToken()).toBe('gho_new');
  });
});
