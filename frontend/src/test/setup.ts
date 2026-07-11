// Registers jest-dom's custom matchers (toBeInTheDocument, toHaveAttribute, …)
// on Vitest's `expect`, and augments the types so `tsc` sees them too.
import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';

// Unmount anything React rendered between tests so DOM state (and the
// document-level listeners / body styles the modal toggles) doesn't leak
// across cases.
afterEach(() => {
  cleanup();
});
