import { describe, it, expect, beforeEach } from 'vitest';
import type { Session } from '../types';
import type { Attention } from './attention';
import {
  attentionCounts,
  newlyPending,
  notificationBody,
  notificationsEnabled,
  repoNameFromUrl,
  setNotificationsEnabled,
} from './notifications';

function session(overrides: Partial<Session> & { sessionId: string }): Session {
  return {
    repoUrl: 'https://github.com/acme/widget.git',
    branch: 'main',
    createdAt: '0',
    ...overrides,
  };
}

beforeEach(() => {
  localStorage.clear();
});

describe('attentionCounts', () => {
  it('counts working and pending sessions, ignoring viewed/idle', () => {
    const sessions = [
      session({ sessionId: 'a', attention: 'working' }),
      session({ sessionId: 'b', attention: 'working' }),
      session({ sessionId: 'c', attention: 'pending' }),
      session({ sessionId: 'd', attention: 'viewed' }),
      session({ sessionId: 'e', attention: 'idle' }),
    ];
    expect(attentionCounts(sessions)).toEqual({ working: 2, pending: 1 });
  });

  it('derives attention locally when the server field is absent (older backend)', () => {
    const sessions = [
      session({ sessionId: 'a', status: 'RUNNING' }),
      session({ sessionId: 'b', status: 'IDLE', pendingCount: '2' }),
      session({ sessionId: 'c' }), // no activity → idle
    ];
    expect(attentionCounts(sessions)).toEqual({ working: 1, pending: 1 });
  });

  it('returns zeros for an empty list', () => {
    expect(attentionCounts([])).toEqual({ working: 0, pending: 0 });
  });
});

describe('newlyPending', () => {
  it('reports a session that transitioned into pending', () => {
    const prev = new Map<string, Attention>([['a', 'working']]);
    const now = [session({ sessionId: 'a', attention: 'pending' })];
    expect(newlyPending(prev, now).map(s => s.sessionId)).toEqual(['a']);
  });

  it('does NOT fire on first sight (session absent from prevMap)', () => {
    const now = [session({ sessionId: 'a', attention: 'pending' })];
    expect(newlyPending(new Map(), now)).toEqual([]);
  });

  it('does NOT re-fire while a session stays pending', () => {
    const prev = new Map<string, Attention>([['a', 'pending']]);
    const now = [session({ sessionId: 'a', attention: 'pending' })];
    expect(newlyPending(prev, now)).toEqual([]);
  });

  it('fires again after the session recovered and re-entered pending', () => {
    const s = (attention: string) => [session({ sessionId: 'a', attention })];
    // pending → viewed: baseline updates, nothing fires
    const afterRecovery = new Map<string, Attention>([['a', 'viewed']]);
    expect(newlyPending(afterRecovery, s('viewed'))).toEqual([]);
    // viewed → pending again: fires
    expect(newlyPending(afterRecovery, s('pending')).map(x => x.sessionId)).toEqual(['a']);
  });

  it('ignores transitions into non-pending states', () => {
    const prev = new Map<string, Attention>([['a', 'pending'], ['b', 'idle']]);
    const now = [
      session({ sessionId: 'a', attention: 'viewed' }),
      session({ sessionId: 'b', attention: 'working' }),
    ];
    expect(newlyPending(prev, now)).toEqual([]);
  });
});

describe('notificationsEnabled / setNotificationsEnabled', () => {
  it('defaults to off (opt-in)', () => {
    expect(notificationsEnabled()).toBe(false);
  });

  it('round-trips through localStorage', () => {
    setNotificationsEnabled(true);
    expect(notificationsEnabled()).toBe(true);
    expect(localStorage.getItem('cloud_agents_notify')).toBe('1');
    setNotificationsEnabled(false);
    expect(notificationsEnabled()).toBe(false);
    expect(localStorage.getItem('cloud_agents_notify')).toBe('0');
  });
});

describe('notificationBody', () => {
  it('builds "repo · branch — needs your attention" from the repoUrl tail', () => {
    expect(notificationBody(session({ sessionId: 'a' }))).toBe(
      'widget · main — needs your attention',
    );
  });

  it('handles trailing slashes and URLs without .git', () => {
    expect(repoNameFromUrl('https://github.com/acme/widget/')).toBe('widget');
    expect(repoNameFromUrl('https://github.com/acme/widget')).toBe('widget');
  });

  it('omits the branch separator when branch is empty', () => {
    expect(notificationBody(session({ sessionId: 'a', branch: '' }))).toBe(
      'widget — needs your attention',
    );
  });
});
