import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { apiFetch } from './api';
import { getStoredOrgId, storeOrgId } from './activeOrg';

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function headerOf(fetchMock: ReturnType<typeof vi.fn>, name: string): string | null {
  const init = fetchMock.mock.calls[0]![1] as RequestInit | undefined;
  return new Headers(init?.headers).get(name);
}

describe('apiFetch organisation header', () => {
  it('sends no X-CloudAgents-Org header for the personal organisation', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    await apiFetch('/api/sessions', { headers: { Authorization: 'Bearer t' } });
    expect(headerOf(fetchMock, 'X-CloudAgents-Org')).toBeNull();
    expect(headerOf(fetchMock, 'Authorization')).toBe('Bearer t');
  });

  it('sends the header, keeping existing headers, when another organisation is active', async () => {
    storeOrgId('org-1');
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    await apiFetch('/api/sessions', { headers: { Authorization: 'Bearer t' } });
    expect(headerOf(fetchMock, 'X-CloudAgents-Org')).toBe('org-1');
    expect(headerOf(fetchMock, 'Authorization')).toBe('Bearer t');
  });

  it('falls back to personal on a 403 that mentions the organisation', async () => {
    storeOrgId('org-1');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{"error":"not a member of this organisation"}', { status: 403 })));
    const res = await apiFetch('/api/sessions');
    expect(res.status).toBe(403);
    expect(getStoredOrgId()).toBe('');
  });

  it('keeps the selection on an unrelated 403', async () => {
    storeOrgId('org-1');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{"error":"forbidden"}', { status: 403 })));
    await apiFetch('/api/sessions');
    expect(getStoredOrgId()).toBe('org-1');
  });
});
