import { describe, it, expect, beforeEach, vi } from 'vitest';

/// #599: harnessAvailability.ts had zero test coverage, including for the
/// previously-fixed null-caching bug (#584) — only a SUCCESSFUL lookup should
/// be cached; a failed/unknown (null) one must retry on the next call rather
/// than replaying the same stale null for the rest of the page session.
///
/// The module caches into a plain module-level variable with no exported
/// reset hook, so each test gets a fresh module instance via
/// `vi.resetModules()` + a fresh dynamic import, and mocks `./api` per test
/// with `vi.doMock` (rather than the file-level `vi.mock` used elsewhere in
/// this codebase) so each import sees its own mock implementation.
describe('enabledHarnesses (#599)', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  it('caches a successful lookup — a later call does not hit the backend again', async () => {
    vi.doMock('./api', () => ({
      api: { getEnabledHarnesses: vi.fn().mockResolvedValue(['claude', 'codex']) },
    }));
    const { enabledHarnesses } = await import('./harnessAvailability');
    const { api } = await import('./api');

    const first = await enabledHarnesses();
    expect(first).toEqual(new Set(['claude', 'codex']));
    expect(api.getEnabledHarnesses).toHaveBeenCalledTimes(1);

    const second = await enabledHarnesses();
    expect(second).toEqual(new Set(['claude', 'codex']));
    // Still just the one call — the second resolved straight from the cache.
    expect(api.getEnabledHarnesses).toHaveBeenCalledTimes(1);
  });

  it('does NOT cache a null (failure/unknown) result — a later call retries (#584)', async () => {
    vi.doMock('./api', () => ({
      api: { getEnabledHarnesses: vi.fn().mockResolvedValue(null) },
    }));
    const { enabledHarnesses } = await import('./harnessAvailability');
    const { api } = await import('./api');

    const first = await enabledHarnesses();
    expect(first).toBeNull();
    expect(api.getEnabledHarnesses).toHaveBeenCalledTimes(1);

    const second = await enabledHarnesses();
    expect(second).toBeNull();
    // A null must not be cached — the second call hit the backend again
    // instead of replaying the first call's stale null forever.
    expect(api.getEnabledHarnesses).toHaveBeenCalledTimes(2);
  });

  it('a transient failure does not poison later successful lookups, which then DO get cached', async () => {
    const getEnabledHarnesses = vi
      .fn()
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(['claude']);
    vi.doMock('./api', () => ({ api: { getEnabledHarnesses } }));
    const { enabledHarnesses } = await import('./harnessAvailability');

    expect(await enabledHarnesses()).toBeNull();
    expect(await enabledHarnesses()).toEqual(new Set(['claude']));
    // A third call reuses the cached success rather than calling again.
    expect(await enabledHarnesses()).toEqual(new Set(['claude']));
    expect(getEnabledHarnesses).toHaveBeenCalledTimes(2);
  });
});
