import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { Session } from '../types';

let mockSessions: Session[] = [];
vi.mock('../context/SessionsContext', () => ({
  useSessions: () => ({ sessions: mockSessions }),
}));

import { AttentionStatus } from './AttentionStatus';

function session(overrides: Partial<Session> & { sessionId: string }): Session {
  return {
    repoUrl: 'https://github.com/acme/widget.git',
    branch: 'main',
    createdAt: '0',
    ...overrides,
  };
}

function renderStatus() {
  return render(
    <MemoryRouter>
      <AttentionStatus />
    </MemoryRouter>,
  );
}

/** Notification stub: a class carrying the `permission` static the component
 *  and hook read, with a spy recording constructor calls. */
function stubNotification(permission: NotificationPermission = 'granted') {
  const constructed = vi.fn();
  class MockNotification {
    static permission: NotificationPermission = permission;
    static requestPermission = vi.fn(async () => MockNotification.permission);
    onclick: (() => void) | null = null;
    constructor(title: string, options?: NotificationOptions) {
      constructed(title, options);
    }
  }
  vi.stubGlobal('Notification', MockNotification);
  return { constructed, MockNotification };
}

beforeEach(() => {
  localStorage.clear();
  mockSessions = [];
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('AttentionStatus', () => {
  it('renders working and pending counts from the session list', () => {
    mockSessions = [
      session({ sessionId: 'a', attention: 'working' }),
      session({ sessionId: 'b', attention: 'working' }),
      session({ sessionId: 'c', attention: 'pending' }),
      session({ sessionId: 'd', attention: 'viewed' }),
    ];
    renderStatus();
    expect(screen.getByTitle('2 working')).toHaveTextContent('2');
    const pendingLink = screen.getByRole('link', { name: '1 session pending — needs you' });
    expect(pendingLink).toHaveAttribute('href', '/sessions?filter=pending');
    expect(pendingLink).toHaveAttribute('title', '1 pending — needs you');
  });

  it('hides both counters when the counts are zero', () => {
    mockSessions = [session({ sessionId: 'a', attention: 'viewed' })];
    renderStatus();
    expect(screen.queryByTitle(/working/)).toBeNull();
    expect(screen.queryByRole('link')).toBeNull();
  });

  it('hides the bell when the Notification API is absent (jsdom default)', () => {
    renderStatus();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('shows the bell with an explanatory title when the API exists', () => {
    stubNotification('granted');
    localStorage.setItem('cloud_agents_notify', '1');
    renderStatus();
    expect(screen.getByRole('button', { name: 'Notifications on' })).toBeInTheDocument();
  });

  it('reports blocked state when permission is denied', () => {
    stubNotification('denied');
    renderStatus();
    expect(screen.getByRole('button', { name: 'Notifications blocked' })).toBeInTheDocument();
  });

  it('fires a Notification when a session transitions into pending (enabled + granted)', () => {
    const { constructed } = stubNotification('granted');
    localStorage.setItem('cloud_agents_notify', '1');
    mockSessions = [session({ sessionId: 's1', attention: 'working' })];
    const { rerender } = renderStatus();
    // First sight only seeds the baseline — nothing fires yet.
    expect(constructed).not.toHaveBeenCalled();

    mockSessions = [session({ sessionId: 's1', attention: 'pending' })];
    rerender(
      <MemoryRouter>
        <AttentionStatus />
      </MemoryRouter>,
    );
    expect(constructed).toHaveBeenCalledTimes(1);
    expect(constructed).toHaveBeenCalledWith(
      'Agent needs you',
      expect.objectContaining({
        tag: 's1',
        body: 'widget · main — needs your attention',
      }),
    );
  });

  it('does not fire when notifications are disabled, and does not backfire after enabling', () => {
    const { constructed } = stubNotification('granted');
    // opt-in flag NOT set — disabled (the default)
    mockSessions = [session({ sessionId: 's1', attention: 'working' })];
    const { rerender } = renderStatus();

    mockSessions = [session({ sessionId: 's1', attention: 'pending' })];
    rerender(
      <MemoryRouter>
        <AttentionStatus />
      </MemoryRouter>,
    );
    expect(constructed).not.toHaveBeenCalled();

    // Enable now; the session is STILL pending — the baseline was updated on
    // the disabled path, so no stale notification fires.
    localStorage.setItem('cloud_agents_notify', '1');
    mockSessions = [session({ sessionId: 's1', attention: 'pending' })];
    rerender(
      <MemoryRouter>
        <AttentionStatus />
      </MemoryRouter>,
    );
    expect(constructed).not.toHaveBeenCalled();
  });
});
