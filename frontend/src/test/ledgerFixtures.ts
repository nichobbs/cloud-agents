import type { LedgerEntry, WorkItem } from '../lib/ledger';

/** Test fixtures for session-ledger rows: a complete row with overrides. */
export function entry(over: Partial<LedgerEntry>): LedgerEntry {
  return {
    id: 'e',
    sessionId: 's1',
    itemId: '',
    kind: 'decision',
    severity: 'info',
    declaredSeverity: '',
    summary: 'x',
    detail: '',
    optionsConsidered: [],
    chosen: '',
    rationale: '',
    recommendation: '',
    proceedingWith: '',
    reversible: '',
    files: [],
    tags: [],
    source: 'declared',
    undeclared: 'false',
    matchedEntryId: '',
    origin: '',
    supersedes: '',
    transcriptSeq: '',
    reviewState: 'not_required',
    reviewBy: '',
    reviewAt: '',
    reviewComment: '',
    createdAt: '1',
    createdSeq: '1',
    updatedSeq: '1',
    ...over,
  };
}

export function item(over: Partial<WorkItem>): WorkItem {
  return {
    id: 'gh:a/b#1',
    sessionId: 's1',
    title: '',
    url: '',
    state: 'queued',
    blockedBy: [],
    blockedReason: '',
    prerequisiteProposal: '',
    recommendation: '',
    prUrl: '',
    order: '0',
    createdAt: '1',
    updatedAt: '1',
    updatedSeq: '1',
    ...over,
  };
}
