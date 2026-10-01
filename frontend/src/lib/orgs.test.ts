import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { orgsApi } from './orgs';

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('orgsApi', () => {
  it('changes a role with POST (Lyric.Web has no PUT route)', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response('{"ok":true}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    await orgsApi.setRole('org-1', 'gh-2', 'admin');
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/api/orgs/org-1/members/gh-2');
    expect(init.method).toBe('POST');
    expect(init.body).toBe('{"role":"admin"}');
  });

  it('surfaces the server error text on a 400', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{"error":"invitation expired"}', { status: 400 })));
    await expect(orgsApi.acceptInvitation('tok')).rejects.toThrow('invitation expired');
  });
});
