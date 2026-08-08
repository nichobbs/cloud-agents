import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useAttentionNotifications } from '../hooks/useAttentionNotifications';
import { notificationsEnabled, setNotificationsEnabled } from '../lib/notifications';

/** Nav-bar attention widget: green dot + count of `working` sessions, amber
 *  dot + count of `pending` sessions (links to the pending-filtered list),
 *  and a bell that toggles browser notifications. Mounts
 *  useAttentionNotifications — the app's ONE mount point for it — so this
 *  must be rendered exactly once, inside the Router (Nav is). Lives in the
 *  always-visible .nav-bar (not the collapsible .nav-links) so the counters
 *  stay visible on mobile where the link panel is behind the hamburger. */
export function AttentionStatus() {
  const { working, pending } = useAttentionNotifications();
  // Older Safari / plain-http contexts have no Notification API — hide the
  // bell entirely there (the counters still work; they don't need it).
  const hasApi = typeof Notification !== 'undefined';
  const [enabled, setEnabled] = useState(notificationsEnabled);
  const [permission, setPermission] = useState<NotificationPermission>(() =>
    hasApi ? Notification.permission : 'default',
  );

  const bellOn = hasApi && enabled && permission === 'granted';
  const bellTitle =
    permission === 'denied'
      ? 'Notifications blocked'
      : bellOn
        ? 'Notifications on'
        : 'Notifications off';

  const handleBell = async () => {
    if (!hasApi) return;
    if (Notification.permission !== 'granted') {
      const result = await Notification.requestPermission();
      setPermission(result);
      if (result === 'granted') {
        setNotificationsEnabled(true);
        setEnabled(true);
      }
      return;
    }
    setPermission('granted');
    const next = !notificationsEnabled();
    setNotificationsEnabled(next);
    setEnabled(next);
  };

  return (
    <span style={rootStyle}>
      {working > 0 && (
        <span
          style={counterStyle}
          title={`${working} working`}
          aria-label={`${working} ${working === 1 ? 'session' : 'sessions'} working`}
        >
          <span style={{ ...dotStyle, background: '#3fb950' }} aria-hidden="true" />
          <span style={{ ...countStyle, color: '#3fb950' }}>{working}</span>
        </span>
      )}
      {pending > 0 && (
        <Link
          to="/sessions?filter=pending"
          style={{ ...counterStyle, textDecoration: 'none' }}
          title={`${pending} pending — needs you`}
          aria-label={`${pending} ${pending === 1 ? 'session' : 'sessions'} pending — needs you`}
        >
          <span style={{ ...dotStyle, background: '#d29922' }} aria-hidden="true" />
          <span style={{ ...countStyle, color: '#d29922' }}>{pending}</span>
        </Link>
      )}
      {hasApi && (
        <button
          type="button"
          style={bellStyle}
          onClick={handleBell}
          title={bellTitle}
          aria-label={bellTitle}
        >
          {bellOn ? '\u{1F514}' : '\u{1F515}'}
        </button>
      )}
    </span>
  );
}

const rootStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '10px',
};

const counterStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '5px',
};

const dotStyle: React.CSSProperties = {
  display: 'inline-block',
  width: '8px',
  height: '8px',
  borderRadius: '50%',
  flexShrink: 0,
};

const countStyle: React.CSSProperties = {
  fontSize: '13px',
  fontWeight: 600,
  lineHeight: 1,
};

const bellStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  padding: '2px 4px',
  border: 'none',
  background: 'transparent',
  fontSize: '14px',
  lineHeight: 1,
  cursor: 'pointer',
};
