import { describe, it, expect } from 'vitest';
import { pwaOptions } from './pwaOptions';

describe('pwaOptions', () => {
  it('excludes /api from the service worker navigation fallback (#552)', () => {
    // The backend owns everything under /api (REST + the phase-6 SSE streams).
    // If the SW ever answered an /api navigation with the precached
    // index.html, live data would break silently. Guard the denylist so a
    // future config edit can't drop it.
    const denylist = pwaOptions.workbox?.navigateFallbackDenylist as RegExp[] | undefined;
    expect(denylist).toBeDefined();
    const patterns = denylist!;
    // Real API paths (all under /api/...) are denied the SPA fallback.
    expect(patterns.some((re) => re.test('/api/sessions/abc/messages'))).toBe(true);
    expect(patterns.some((re) => re.test('/api/health'))).toBe(true);
    // A normal client-side route must NOT be denied — it should still fall
    // back to the app shell.
    expect(patterns.some((re) => re.test('/sessions/abc'))).toBe(false);
  });

  it('declares a standalone, installable manifest with a maskable icon', () => {
    const manifest = pwaOptions.manifest;
    if (!manifest) throw new Error('expected a manifest');
    expect(manifest.display).toBe('standalone');
    expect(manifest.start_url).toBe('/');
    const icons = manifest.icons ?? [];
    expect(icons.some((i) => i.sizes === '192x192')).toBe(true);
    expect(icons.some((i) => i.sizes === '512x512')).toBe(true);
    expect(icons.some((i) => i.purpose === 'maskable')).toBe(true);
  });

  it('does not lock orientation, so an installed PWA can rotate (#550)', () => {
    const manifest = pwaOptions.manifest;
    if (!manifest) throw new Error('expected a manifest');
    expect(manifest.orientation).toBeUndefined();
  });
});
