import { useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessions } from '../context/SessionsContext';
import type { Attention } from '../lib/attention';
import { sessionAttention } from '../lib/attention';
import {
  attentionCounts,
  newlyPending,
  notificationBody,
  notificationsEnabled,
} from '../lib/notifications';

/** Watches the polled session list (SessionsContext refreshes every 15s) and
 *  fires a browser Notification whenever a session transitions into `pending`
 *  — except for the session the user is currently looking at. Must be mounted
 *  exactly once, inside both SessionsProvider and the Router (it navigates on
 *  notification click). Returns the current working/pending counts so the one
 *  mount point (AttentionStatus in the nav) can render them for free. */
export function useAttentionNotifications(): { working: number; pending: number } {
  const { sessions } = useSessions();
  const navigate = useNavigate();
  // Previous attention per sessionId; starts empty so the first poll after
  // mount only seeds the map (first sight is not a transition).
  const prevRef = useRef<Map<string, Attention>>(new Map());

  useEffect(() => {
    if (
      notificationsEnabled() &&
      typeof Notification !== 'undefined' &&
      Notification.permission === 'granted'
    ) {
      for (const s of newlyPending(prevRef.current, sessions)) {
        // Don't notify about the session the user is actively looking at.
        const isOpenAndVisible =
          window.location.pathname === `/sessions/${s.sessionId}` &&
          document.visibilityState === 'visible';
        if (isOpenAndVisible) continue;
        const n = new Notification('Agent needs you', {
          body: notificationBody(s),
          // tag dedupes: a re-fire for the same session replaces, not stacks.
          tag: s.sessionId,
        });
        n.onclick = () => {
          window.focus();
          navigate(`/sessions/${s.sessionId}`);
        };
      }
    }
    // ALWAYS update the baseline — including when disabled or permission is
    // missing — so enabling notifications later doesn't backfire a burst of
    // stale transitions that happened while they were off.
    prevRef.current = new Map(sessions.map(s => [s.sessionId, sessionAttention(s)]));
  }, [sessions, navigate]);

  return attentionCounts(sessions);
}
