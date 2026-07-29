/// Shared timestamp helpers. Backend timestamps are epoch-milliseconds encoded
/// as strings (the SQLite driver is TEXT-only); locally-created values may be
/// ISO strings. Everything here accepts both and degrades to '' on garbage.

/** Parse an epoch-millis string or ISO date string to millis, or NaN. */
export function parseTimestamp(value: string | undefined | null): number {
  if (!value) return NaN;
  const n = Number(value);
  if (Number.isFinite(n)) {
    // Purely numeric input is epoch millis; zero/negative means "unset"
    // (never date-parse it — new Date('0') would read as a year).
    return n > 0 ? n : NaN;
  }
  const d = new Date(value).getTime();
  return Number.isFinite(d) ? d : NaN;
}

/** "14:32:05" for today, "12 Jul 14:32" otherwise. '' for garbage. */
export function formatTimestamp(value: string | undefined | null): string {
  const ms = parseTimestamp(value);
  if (!Number.isFinite(ms)) return '';
  const d = new Date(ms);
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  if (sameDay) {
    return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }
  return d.toLocaleString(undefined, {
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
}

/** Full locale timestamp for tooltips. '' for garbage. */
export function formatFullTimestamp(value: string | undefined | null): string {
  const ms = parseTimestamp(value);
  if (!Number.isFinite(ms)) return '';
  return new Date(ms).toLocaleString();
}

/** "just now" / "5m ago" / "3h ago" / "2d ago". '' for garbage. */
export function timeAgo(value: string | undefined | null): string {
  const ms = parseTimestamp(value);
  if (!Number.isFinite(ms)) return '';
  const diff = Date.now() - ms;
  if (!Number.isFinite(diff) || diff < 0) return 'just now';
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

/** "0:07" / "2:13" / "1:02:13" from a millisecond duration. */
export function formatElapsed(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '0:00';
  const totalSec = Math.floor(ms / 1000);
  const s = totalSec % 60;
  const m = Math.floor(totalSec / 60) % 60;
  const h = Math.floor(totalSec / 3600);
  const two = (n: number) => n.toString().padStart(2, '0');
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}
