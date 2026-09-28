import { describe, expect, it } from 'vitest';
import { entry, item } from '../test/ledgerFixtures';
import {
  applySnapshot,
  attentionQueue,
  blockedEdges,
  EMPTY_LEDGER,
  humanActions,
  progress,
  refLabel,
  refUrl,
  safeHref,
  type LedgerSnapshot,
  type LedgerSummary,
} from './ledger';

const summary: LedgerSummary = {
  sessionId: 's1',
  total: '3',
  queued: '1',
  inProgress: '0',
  prOpen: '0',
  done: '1',
  blocked: '1',
  needsHuman: '0',
  skipped: '0',
  pendingReview: '1',
  blockingCount: '1',
  undeclaredCount: '0',
  pendingFeedback: '0',
  lastActivityAt: '5',
};

function snap(over: Partial<LedgerSnapshot>): LedgerSnapshot {
  return {
    cursor: '1',
    unchanged: 'false',
    full: 'true',
    summary,
    items: [],
    entries: [],
    feedback: [],
    policyStatus: '',
    policyError: '',
    ...over,
  };
}

describe('applySnapshot', () => {
  it('replaces everything on a full snapshot', () => {
    const s = applySnapshot(EMPTY_LEDGER, snap({ cursor: '4', items: [item({})], entries: [entry({ id: 'a' })] }));
    expect(s.cursor).toBe('4');
    expect(s.items).toHaveLength(1);
    expect(s.entries.map(e => e.id)).toEqual(['a']);
  });

  it('upserts changed rows from a delta, keeping order', () => {
    const start = applySnapshot(
      EMPTY_LEDGER,
      snap({
        cursor: '2',
        items: [item({ id: 'gh:a/b#1', order: '0' }), item({ id: 'gh:a/b#2', order: '1' })],
        entries: [entry({ id: 'a', createdSeq: '1' })],
      }),
    );
    const next = applySnapshot(
      start,
      snap({
        cursor: '3',
        full: 'false',
        items: [item({ id: 'gh:a/b#1', order: '0', state: 'done' })],
        entries: [entry({ id: 'b', createdSeq: '3' }), entry({ id: 'a', createdSeq: '1', reviewState: 'approved' })],
      }),
    );
    expect(next.cursor).toBe('3');
    expect(next.items.map(i => [i.id, i.state])).toEqual([
      ['gh:a/b#1', 'done'],
      ['gh:a/b#2', 'queued'],
    ]);
    expect(next.entries.map(e => [e.id, e.reviewState])).toEqual([
      ['a', 'approved'],
      ['b', 'not_required'],
    ]);
  });

  it('keeps rows when nothing changed but takes the fresh summary', () => {
    const start = applySnapshot(EMPTY_LEDGER, snap({ items: [item({})] }));
    const next = applySnapshot(start, snap({ unchanged: 'true', full: 'false', summary: { ...summary, total: '9' } }));
    expect(next.items).toHaveLength(1);
    expect(next.summary?.total).toBe('9');
  });
});

describe('attentionQueue', () => {
  it('lists pending review entries, blocking first then oldest first', () => {
    const q = attentionQueue([
      entry({ id: 'info', severity: 'info', reviewState: 'not_required', createdSeq: '1' }),
      entry({ id: 'r1', severity: 'review', reviewState: 'pending', createdSeq: '2' }),
      entry({ id: 'b1', severity: 'blocking', reviewState: 'pending', createdSeq: '5' }),
      entry({ id: 'done', severity: 'review', reviewState: 'approved', createdSeq: '3' }),
      entry({ id: 'resolved', severity: 'blocking', reviewState: 'resolved', createdSeq: '4' }),
    ]);
    expect(q.map(e => e.id)).toEqual(['b1', 'r1']);
  });
});

describe('item helpers', () => {
  it('offers only the transitions the backend allows a human', () => {
    expect(humanActions('blocked').map(a => a.to)).toEqual(['queued', 'skipped']);
    expect(humanActions('in_progress')).toEqual([]);
    expect(humanActions('pr_open')).toEqual([]);
    expect(humanActions('done').map(a => a.to)).toEqual(['in_progress']);
  });

  it('labels and links refs', () => {
    expect(refLabel('gh:acme/shop#12')).toBe('acme/shop#12');
    expect(refLabel('local:tidy')).toBe('tidy');
    expect(refUrl('gh:acme/shop#12')).toBe('https://github.com/acme/shop/issues/12');
    expect(refUrl('local:tidy')).toBe('');
  });

  it('lists blocked items with what they wait on', () => {
    const edges = blockedEdges([item({ id: 'x', state: 'blocked', blockedBy: ['gh:a/b#1'] }), item({ id: 'y' })]);
    expect(edges.map(e => [e.item.id, e.waitsOn])).toEqual([['x', ['gh:a/b#1']]]);
  });

  it('counts skipped items as resolved progress', () => {
    expect(progress({ ...summary, done: '1', skipped: '1', total: '4' })).toEqual({ resolved: 2, total: 4 });
    expect(progress(null)).toEqual({ resolved: 0, total: 0 });
  });
});

describe('safeHref', () => {
  it('keeps http(s) links and drops script or relative ones', () => {
    expect(safeHref('https://github.com/acme/shop/pull/3')).toBe('https://github.com/acme/shop/pull/3');
    expect(safeHref('http://example.test/x')).toBe('http://example.test/x');
    expect(safeHref("javascript:alert('x')")).toBe('');
    expect(safeHref(' JavaScript:alert(1)')).toBe('');
    expect(safeHref('data:text/html,<b>x</b>')).toBe('');
    expect(safeHref('/relative')).toBe('');
    expect(safeHref('')).toBe('');
  });
});
