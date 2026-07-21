import { beforeEach, describe, expect, it } from 'vitest';
import { clearFailedDraft, saveFailedDraft, takeFailedDraft } from './drafts';

beforeEach(() => {
  localStorage.clear();
});

describe('drafts (#104: failed-send prompt recovery)', () => {
  it('round-trips a saved draft and clears it on take (one-shot)', () => {
    saveFailedDraft('session-a', 'hello world');
    expect(takeFailedDraft('session-a')).toBe('hello world');
    // Second take (e.g. re-visiting the session again later) finds nothing —
    // a recovered draft must not keep reappearing.
    expect(takeFailedDraft('session-a')).toBe('');
  });

  it('returns "" for a session with no persisted draft', () => {
    expect(takeFailedDraft('never-saved')).toBe('');
  });

  it('keeps drafts for different sessions independent', () => {
    saveFailedDraft('session-a', 'a text');
    saveFailedDraft('session-b', 'b text');
    expect(takeFailedDraft('session-a')).toBe('a text');
    expect(takeFailedDraft('session-b')).toBe('b text');
  });

  it('overwrites a prior draft for the same session', () => {
    saveFailedDraft('session-a', 'first attempt');
    saveFailedDraft('session-a', 'second attempt');
    expect(takeFailedDraft('session-a')).toBe('second attempt');
  });

  it('clearFailedDraft removes a draft without needing to read it', () => {
    saveFailedDraft('session-a', 'stale after a later success');
    clearFailedDraft('session-a');
    expect(takeFailedDraft('session-a')).toBe('');
  });

  it('clearFailedDraft on a session with nothing saved is a no-op', () => {
    expect(() => clearFailedDraft('nothing-here')).not.toThrow();
  });

  it('survives malformed existing storage instead of throwing', () => {
    localStorage.setItem('cloud_agents_failed_drafts', 'not json');
    expect(() => saveFailedDraft('session-a', 'text')).not.toThrow();
    expect(takeFailedDraft('session-a')).toBe('text');
  });

  // #600: the above "not json" case is invalid JSON *syntax*, already caught
  // by JSON.parse's own try/catch regardless of loadAll's shape guard (#573:
  // `typeof parsed !== 'object' || Array.isArray(parsed)`) — it never
  // exercises that branch. These cases feed syntactically-VALID JSON of the
  // wrong shape (null, an array, a bare number), which parses fine and would
  // have been cast straight through as a DraftMap before #573's fix, then
  // thrown or misbehaved the moment a caller indexed/assigned into it.
  it.each([
    ['null', 'null'],
    ['an array', '[]'],
    ['a bare number', '42'],
  ])('treats syntactically-valid but wrong-shaped storage (%s) as if empty', (_label, stored) => {
    localStorage.setItem('cloud_agents_failed_drafts', stored);

    // Reading finds nothing, same as genuinely-empty storage.
    expect(takeFailedDraft('session-a')).toBe('');

    // Writing doesn't throw and replaces the bad value with a real map.
    expect(() => saveFailedDraft('session-a', 'text')).not.toThrow();
    expect(takeFailedDraft('session-a')).toBe('text');
  });

  it.each([
    ['null', 'null'],
    ['an array', '[]'],
    ['a bare number', '42'],
  ])('clearFailedDraft on wrong-shaped storage (%s) is a no-op, not a throw', (_label, stored) => {
    localStorage.setItem('cloud_agents_failed_drafts', stored);
    expect(() => clearFailedDraft('session-a')).not.toThrow();
    expect(takeFailedDraft('session-a')).toBe('');
  });
});
