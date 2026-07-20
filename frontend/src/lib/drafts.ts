/// Per-session persistence for a failed-send prompt (#104).
///
/// SessionDetail's handleSend() already restores a failed send's typed text
/// into the composer via setInput() — but only for the session it's still
/// looking at (currentSessionRef/stale guard, #314's pattern). A send can
/// take up to 30 minutes; if the user navigates to a different session
/// before it settles, the setInput() restore would land in the WRONG
/// session's composer, so it's skipped — and before this module existed,
/// that meant the failed prompt was gone for good, with no way to recover
/// it. This persists it per-session instead, so it survives the navigation
/// and is handed back the next time that session is opened.
const STORAGE_KEY = 'cloud_agents_failed_drafts';

type DraftMap = Record<string, string>;

function loadAll(): DraftMap {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}');
    // JSON.parse only throws on malformed syntax — valid-but-wrong-shaped
    // JSON (null, an array, a bare number/string) parses fine and would
    // otherwise be cast straight through as a DraftMap (#573), then throw or
    // misbehave the moment a caller tries to index/assign into it.
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {};
    }
    return parsed as DraftMap;
  } catch {
    return {};
  }
}

function saveAll(map: DraftMap): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
  } catch {
    /* quota — the draft just won't survive navigation, no worse than before this existed */
  }
}

/** Persist a failed send's prompt text for `sessionId` so it can be
 *  recovered next time this session is opened, even after navigating away
 *  before the send settled. */
export function saveFailedDraft(sessionId: string, text: string): void {
  const map = loadAll();
  map[sessionId] = text;
  saveAll(map);
}

/** Read and clear a session's persisted failed draft in one step ('' if
 *  none) — a recovered draft is one-shot: once handed back to the composer,
 *  it shouldn't reappear on a later visit. */
export function takeFailedDraft(sessionId: string): string {
  const map = loadAll();
  const text = map[sessionId];
  if (text === undefined) return '';
  delete map[sessionId];
  saveAll(map);
  return text;
}

/** Clear a session's persisted failed draft without reading it (e.g. once a
 *  fresh send for the same session succeeds, so a later failed send doesn't
 *  get confused with this now-moot one). */
export function clearFailedDraft(sessionId: string): void {
  const map = loadAll();
  if (!(sessionId in map)) return;
  delete map[sessionId];
  saveAll(map);
}
