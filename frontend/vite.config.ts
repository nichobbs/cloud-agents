/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';
import { pwaOptions } from './src/pwaOptions';

export default defineConfig({
  plugins: [react(), VitePWA(pwaOptions)],
  server: {
    proxy: {
      '/api': 'http://localhost:8080',
    },
  },
  test: {
    environment: 'jsdom',
    setupFiles: './src/test/setup.ts',
    // Unit tests import the matchers/vitest primitives explicitly, so no
    // global injection — keeps the production `tsc` build honest without
    // needing vitest globals in tsconfig.
    globals: false,
    css: false,
  },
});
