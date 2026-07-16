import { describe, it, expect } from 'vitest';
import { formatElapsed, formatFullTimestamp, formatTimestamp, parseTimestamp, timeAgo } from './time';

describe('parseTimestamp', () => {
  it('parses epoch-millis strings', () => {
    expect(parseTimestamp('1752537600000')).toBe(1752537600000);
  });

  it('parses ISO strings', () => {
    expect(parseTimestamp('2026-07-15T00:00:00.000Z')).toBe(Date.parse('2026-07-15T00:00:00.000Z'));
  });

  it('returns NaN for garbage / empty', () => {
    expect(Number.isNaN(parseTimestamp(''))).toBe(true);
    expect(Number.isNaN(parseTimestamp('not a date'))).toBe(true);
    expect(Number.isNaN(parseTimestamp(undefined))).toBe(true);
    expect(Number.isNaN(parseTimestamp('0'))).toBe(true);
  });
});

describe('formatTimestamp / formatFullTimestamp', () => {
  it('renders empty for garbage', () => {
    expect(formatTimestamp('garbage')).toBe('');
    expect(formatFullTimestamp('')).toBe('');
  });

  it('renders something for a valid timestamp', () => {
    expect(formatTimestamp(String(Date.now())).length).toBeGreaterThan(0);
    expect(formatFullTimestamp(String(Date.now())).length).toBeGreaterThan(0);
  });
});

describe('timeAgo', () => {
  it('renders relative buckets', () => {
    expect(timeAgo(String(Date.now() - 30_000))).toBe('just now');
    expect(timeAgo(String(Date.now() - 5 * 60_000))).toBe('5m ago');
    expect(timeAgo(String(Date.now() - 3 * 3_600_000))).toBe('3h ago');
    expect(timeAgo(String(Date.now() - 49 * 3_600_000))).toBe('2d ago');
  });

  it('renders empty for garbage (no "NaNd ago")', () => {
    expect(timeAgo('')).toBe('');
    expect(timeAgo('garbage')).toBe('');
  });
});

describe('formatElapsed', () => {
  it('formats sub-hour durations as m:ss', () => {
    expect(formatElapsed(7_000)).toBe('0:07');
    expect(formatElapsed(133_000)).toBe('2:13');
  });

  it('formats hour-plus durations as h:mm:ss', () => {
    expect(formatElapsed(3_733_000)).toBe('1:02:13');
  });

  it('clamps garbage to 0:00', () => {
    expect(formatElapsed(-5)).toBe('0:00');
    expect(formatElapsed(NaN)).toBe('0:00');
  });
});
