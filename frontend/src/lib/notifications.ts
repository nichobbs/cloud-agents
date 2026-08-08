import type { Session } from '../types';
import type { Attention } from './attention';
import { sessionAttention } from './attention';

/** localStorage key for the browser-notification opt-in ('1' on, '0'/absent off). */
const STORAGE_KEY = 'cloud_agents_notify';

/** How many sessions are currently `working` (agent running) and how many are
 *  `pending` (need a human). Used by the nav counters. */
export function attentionCounts(sessions: Session[]): { working: number; pending: number } {
  let working = 0;
  let pending = 0;
  for (const s of sessions) {
    const a = sessionAttention(s);
    if (a === 'working') working += 1;
    else if (a === 'pending') pending += 1;
  }
  return { working, pending };
}

/** Sessions whose attention state just transitioned INTO `pending` relative to
 *  `prevMap` (sessionId → previously observed Attention). A session absent
 *  from `prevMap` never fires — first sight is not a transition, so a page
 *  load with already-pending sessions doesn't produce a notification burst. */
export function newlyPending(prevMap: Map<string, Attention>, sessions: Session[]): Session[] {
  const out: Session[] = [];
  for (const s of sessions) {
    const prev = prevMap.get(s.sessionId);
    if (prev === undefined) continue;
    if (prev !== 'pending' && sessionAttention(s) === 'pending') out.push(s);
  }
  return out;
}

/** Whether the user opted in to browser notifications (default: off). */
export function notificationsEnabled(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === '1';
  } catch {
    return false;
  }
}

export function setNotificationsEnabled(enabled: boolean): void {
  try {
    localStorage.setItem(STORAGE_KEY, enabled ? '1' : '0');
  } catch {
    /* storage unavailable (private mode) — stays session-default off */
  }
}

/** Human-readable repo name: the tail of the repo URL, without `.git`. */
export function repoNameFromUrl(repoUrl: string): string {
  const trimmed = repoUrl.replace(/\/+$/, '');
  const tail = trimmed.slice(trimmed.lastIndexOf('/') + 1);
  const name = tail.endsWith('.git') ? tail.slice(0, -4) : tail;
  return name || repoUrl;
}

/** Short body line for a "needs you" notification, e.g.
 *  "cloud-agents · main — needs your attention". */
export function notificationBody(session: Session): string {
  const repo = repoNameFromUrl(session.repoUrl);
  const where = session.branch ? `${repo} · ${session.branch}` : repo;
  return `${where} — needs your attention`;
}
