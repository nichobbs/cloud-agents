import type { Session } from '../types';

/** VelaTerm-style per-session attention state:
 *  - working: an agent run is in progress
 *  - pending: the session needs a human (pending callback, or activity the
 *    user hasn't seen yet)
 *  - viewed:  there is history and the user has seen all of it
 *  - idle:    fresh session with no activity
 */
export type Attention = 'working' | 'pending' | 'viewed' | 'idle';

export const ATTENTION_META: Record<Attention, { label: string; color: string }> = {
  working: { label: 'Working', color: '#3fb950' },
  pending: { label: 'Pending', color: '#d29922' },
  viewed: { label: 'Viewed', color: '#bc8cff' },
  idle: { label: 'Idle', color: '#484f58' },
};

function toMillis(v: string | undefined): number {
  const n = parseInt(v ?? '0', 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** The session's attention state — the server-derived value when present,
 *  otherwise derived locally from the raw ingredients (older backends omit
 *  `attention`; locally-created sessions omit everything). Must mirror the
 *  backend's attentionFor() rules. */
export function sessionAttention(s: Session): Attention {
  const a = s.attention;
  if (a === 'working' || a === 'pending' || a === 'viewed' || a === 'idle') return a;
  const pendingCount = parseInt(s.pendingCount ?? '0', 10) || 0;
  const last = toMillis(s.lastMessageAt);
  const viewed = toMillis(s.lastViewedAt);
  if (pendingCount > 0) return 'pending';
  if (s.status === 'RUNNING') return 'working';
  if (last > 0 && last > viewed) return 'pending';
  if (last > 0) return 'viewed';
  return 'idle';
}
