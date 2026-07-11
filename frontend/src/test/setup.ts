// Registers jest-dom's custom matchers (toBeInTheDocument, toHaveAttribute, …)
// on Vitest's `expect`, and augments the types so `tsc` sees them too.
import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';

// jsdom doesn't implement scrollIntoView, but components like Terminal call it
// from a mount/update effect (auto-scroll to the newest output). Stub it so
// rendering those components in tests doesn't throw.
if (!Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = () => {};
}

// Unmount anything React rendered between tests so DOM state (and the
// document-level listeners / body styles the modal toggles) doesn't leak
// across cases.
afterEach(() => {
  cleanup();
});
