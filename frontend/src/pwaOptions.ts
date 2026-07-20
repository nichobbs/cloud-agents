// PWA (vite-plugin-pwa / Workbox) options, extracted from vite.config.ts so
// they are type-checked with the app and unit-testable without running a full
// build (#552). This module is plain data — no runtime imports of the plugin —
// so importing it from a test doesn't pull in the Workbox toolchain.
import type { VitePWAOptions } from 'vite-plugin-pwa';

export const pwaOptions: Partial<VitePWAOptions> = {
  // autoUpdate: the service worker installs the new build and takes over on
  // the next navigation without prompting. Suits this app — it's a thin client
  // over a live API, so there's no offline state to preserve across an update.
  registerType: 'autoUpdate',
  includeAssets: ['favicon.ico', 'apple-touch-icon.png'],
  manifest: {
    name: 'Cloud Agents',
    short_name: 'Cloud Agents',
    description: 'Launch, watch, and steer coding-agent sessions from anywhere.',
    // Matches the app shell (src/styles.css --bg-canvas #0d1117); the
    // splash/status bar blend into the UI instead of flashing white.
    theme_color: '#0d1117',
    background_color: '#0d1117',
    display: 'standalone',
    // No orientation lock: the terminal/output views benefit from landscape,
    // so let an installed PWA rotate freely (#550).
    start_url: '/',
    scope: '/',
    icons: [
      { src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' },
      { src: 'pwa-512x512.png', sizes: '512x512', type: 'image/png' },
      {
        src: 'maskable-icon-512x512.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'maskable',
      },
    ],
  },
  workbox: {
    // Precache the built app shell so a launched PWA opens instantly and
    // survives a flaky connection long enough to reach the API.
    globPatterns: ['**/*.{js,css,html,ico,png,svg,woff2}'],
    // SPA fallback for client-side routes — but never for the API: the backend
    // owns everything under /api (REST + SSE streams), so those must always
    // hit the network, never be answered with index.html or a cached response.
    navigateFallback: '/index.html',
    navigateFallbackDenylist: [/^\/api\//],
  },
  // Dev: leave the SW disabled under `vite dev` (default) so HMR isn't shadowed
  // by a cache; it's generated only for `vite build`.
  devOptions: { enabled: false },
};
