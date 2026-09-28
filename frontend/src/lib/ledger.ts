/** Session ledger client model (docs/session-ledger.md): the wire types the
 *  backend's /api/sessions/{id}/ledger endpoints return, and the pure
 *  helpers the ledger views are built from. Every scalar arrives as a string
 *  (this backend's JSON convention); counts are decimal strings. */

export type EntryKind = 'decision' | 'deviation' | 'shortcut' | 'blocker' | 'question' | 'note';
export type Severity = 'info' | 'review' | 'blocking';
export type ReviewState = 'pending' | 'approved' | 'rejected' | 'commented' | 'not_required' | 'resolved';
export type ItemState = 'queued' | 'in_progress' | 'pr_open' | 'done' | 'blocked' | 'needs_human' | 'skipped';

export interface LedgerEntry {
  id: string;
  sessionId: string;
  itemId: string;
  kind: EntryKind;
  severity: Severity;
  declaredSeverity: string;
  summary: string;
  detail: string;
  optionsConsidered: string[];
  chosen: string;
  rationale: string;
  recommendation: string;
  proceedingWith: string;
  reversible: string;
  files: string[];
  tags: string[];
  source: 'declared' | 'observed' | 'system';
  undeclared: string;
  matchedEntryId: string;
  origin: string;
  supersedes: string;
  transcriptSeq: string;
  reviewState: ReviewState;
  reviewBy: string;
  reviewAt: string;
  reviewComment: string;
  createdAt: string;
  createdSeq: string;
  updatedSeq: string;
}

export interface WorkItem {
  id: string;
  sessionId: string;
  title: string;
  url: string;
  state: ItemState;
  blockedBy: string[];
  blockedReason: string;
  prerequisiteProposal: string;
  recommendation: string;
  prUrl: string;
  order: string;
  createdAt: string;
  updatedAt: string;
  updatedSeq: string;
}

export interface LedgerFeedback {
  id: string;
  sessionId: string;
  entryId: string;
  itemId: string;
  kind: 'approve' | 'reject' | 'comment' | 'directive';
  body: string;
  createdBy: string;
  createdAt: string;
  deliveredAt: string;
  deliveredVia: string;
  updatedSeq: string;
}

export interface LedgerSummary {
  sessionId: string;
  total: string;
  queued: string;
  inProgress: string;
  prOpen: string;
  done: string;
  blocked: string;
  needsHuman: string;
  skipped: string;
  pendingReview: string;
  blockingCount: string;
  undeclaredCount: string;
  pendingFeedback: string;
  lastActivityAt: string;
}

/** What a GitHub sync did (counts are decimal strings). */
export interface LedgerSyncReport {
  sessions: string;
  items: string;
  transitions: string;
  calls: string;
  errors: string[];
}

export interface LedgerSnapshot {
  cursor: string;
  unchanged: string;
  full: string;
  /** "true" on a full snapshot that left older entries or feedback out
   *  (past the server's row caps; the newest are kept). Absent on older
   *  backends. */
  truncated?: string;
  summary: LedgerSummary;
  items: WorkItem[];
  entries: LedgerEntry[];
  feedback: LedgerFeedback[];
  policyStatus: string;
  policyError: string;
}

export interface ItemTransition {
  itemId: string;
  fromState: string;
  toState: string;
  actor: string;
  reason: string;
  at: string;
}

export interface EntryDetail {
  ledgerEntry: LedgerEntry;
  feedback: LedgerFeedback[];
  transitions: ItemTransition[];
  transcriptExcerpt: string;
  supersededBy: string[];
}

export interface InboxEntry {
  ledgerEntry: LedgerEntry;
  repoUrl: string;
  branch: string;
}

/** The client-side ledger state a view renders: the latest snapshot merged
 *  with every delta since. */
export interface LedgerState {
  cursor: string;
  /** Older entries/feedback were left out of the last full snapshot. */
  truncated: boolean;
  summary: LedgerSummary | null;
  items: WorkItem[];
  entries: LedgerEntry[];
  feedback: LedgerFeedback[];
  policyStatus: string;
  policyError: string;
}

export const EMPTY_LEDGER: LedgerState = {
  cursor: '0',
  truncated: false,
  summary: null,
  items: [],
  entries: [],
  feedback: [],
  policyStatus: '',
  policyError: '',
};

function num(s: string | undefined): number {
  const n = parseInt(s ?? '0', 10);
  return Number.isFinite(n) ? n : 0;
}

/** Replace-or-append by id, then order by a numeric key (stable for ties). */
function upsert<T extends { id: string }>(current: T[], changed: T[], order: (t: T) => number): T[] {
  if (changed.length === 0) return current;
  const byId = new Map(current.map(x => [x.id, x]));
  for (const c of changed) byId.set(c.id, c);
  return [...byId.values()].sort((a, b) => order(a) - order(b));
}

/** Fold a snapshot from GET /ledger?after=<cursor> into the view state. A
 *  full snapshot replaces everything; a delta upserts the changed rows. */
export function applySnapshot(state: LedgerState, snap: LedgerSnapshot): LedgerState {
  const base = {
    cursor: snap.cursor,
    summary: snap.summary,
    policyStatus: snap.policyStatus,
    policyError: snap.policyError,
  };
  if (snap.full === 'true') {
    return {
      ...base,
      truncated: snap.truncated === 'true',
      items: snap.items,
      entries: snap.entries,
      feedback: snap.feedback,
    };
  }
  if (snap.unchanged === 'true') {
    return { ...state, ...base };
  }
  return {
    ...base,
    truncated: state.truncated,
    items: upsert(state.items, snap.items, i => num(i.order)),
    entries: upsert(state.entries, snap.entries, e => num(e.createdSeq)),
    feedback: upsert(state.feedback, snap.feedback, f => num(f.createdAt)),
  };
}

/** Whether an entry is waiting for a human review. */
export function needsAttention(e: LedgerEntry): boolean {
  return e.reviewState === 'pending' && (e.severity === 'review' || e.severity === 'blocking');
}

/** The attention queue: pending entries, blocking first, then oldest first. */
export function attentionQueue(entries: LedgerEntry[]): LedgerEntry[] {
  return entries
    .filter(needsAttention)
    .sort((a, b) => {
      const sa = a.severity === 'blocking' ? 0 : 1;
      const sb = b.severity === 'blocking' ? 0 : 1;
      return sa !== sb ? sa - sb : num(a.createdSeq) - num(b.createdSeq);
    });
}

export const ITEM_STATE_META: Record<ItemState, { label: string; color: string }> = {
  queued: { label: 'queued', color: '#8b949e' },
  in_progress: { label: 'in progress', color: '#58a6ff' },
  pr_open: { label: 'PR open', color: '#a371f7' },
  done: { label: 'done', color: '#3fb950' },
  blocked: { label: 'blocked', color: '#f85149' },
  needs_human: { label: 'needs you', color: '#d29922' },
  skipped: { label: 'skipped', color: '#6e7681' },
};

export const KIND_META: Record<EntryKind, { label: string; color: string }> = {
  decision: { label: 'decision', color: '#58a6ff' },
  deviation: { label: 'deviation', color: '#d29922' },
  shortcut: { label: 'shortcut', color: '#f0883e' },
  blocker: { label: 'blocker', color: '#f85149' },
  question: { label: 'question', color: '#a371f7' },
  note: { label: 'note', color: '#8b949e' },
};

/** The human transitions offered for an item, mirroring the backend state
 *  machine's human-actor rows (docs/session-ledger.md §4). */
export function humanActions(state: ItemState): Array<{ to: ItemState; label: string }> {
  switch (state) {
    case 'queued':
      return [{ to: 'skipped', label: 'Skip' }, { to: 'needs_human', label: 'Hold for me' }];
    case 'blocked':
      return [{ to: 'queued', label: 'Unblock' }, { to: 'skipped', label: 'Skip' }];
    case 'needs_human':
      return [{ to: 'queued', label: 'Requeue' }, { to: 'skipped', label: 'Skip' }];
    case 'skipped':
      return [{ to: 'queued', label: 'Requeue' }];
    case 'done':
      return [{ to: 'in_progress', label: 'Reopen' }];
    default:
      return [];
  }
}

/** Short display form of a canonical ref: gh:acme/shop#12 -> acme/shop#12,
 *  local:x -> x. */
export function refLabel(ref: string): string {
  if (ref.startsWith('gh:')) return ref.slice(3);
  if (ref.startsWith('local:')) return ref.slice(6);
  return ref;
}

/** The GitHub URL for a gh: ref, or '' for anything else. */
export function refUrl(ref: string): string {
  const m = /^gh:([^/]+\/[^#]+)#(\d+)$/.exec(ref);
  return m ? `https://github.com/${m[1]}/issues/${m[2]}` : '';
}

/** `url` if it is safe to render as a clickable link (absolute http(s)),
 *  else ''. Link fields are agent-supplied: a `javascript:` URL here would
 *  run in the owner's session on click. The backend rejects these too. */
export function safeHref(url: string): string {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : '';
  } catch {
    return '';
  }
}

/** Feedback on `entryId` / for `itemId`, newest first. */
export function feedbackFor(feedback: LedgerFeedback[], entryId: string): LedgerFeedback[] {
  return feedback.filter(f => f.entryId === entryId).sort((a, b) => num(b.createdAt) - num(a.createdAt));
}

/** Blocked items and what each waits on, for the dependency view. */
export function blockedEdges(items: WorkItem[]): Array<{ item: WorkItem; waitsOn: string[] }> {
  return items
    .filter(i => i.state === 'blocked')
    .map(i => ({ item: i, waitsOn: i.blockedBy }));
}

/** Progress as done / total, counting skipped as resolved. */
export function progress(summary: LedgerSummary | null): { resolved: number; total: number } {
  if (!summary) return { resolved: 0, total: 0 };
  return { resolved: num(summary.done) + num(summary.skipped), total: num(summary.total) };
}
