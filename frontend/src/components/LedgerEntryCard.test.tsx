import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';

vi.mock('../lib/api', () => ({
  api: {
    getLedgerEntry: vi.fn(),
    reviewLedgerEntry: vi.fn(),
  },
}));

import { api } from '../lib/api';
import type { EntryDetail, LedgerEntry } from '../lib/ledger';
import { entry } from '../test/ledgerFixtures';
import { LedgerEntryCard } from './LedgerEntryCard';

function detailOf(e: LedgerEntry, feedbackBodies: string[]): EntryDetail {
  return {
    ledgerEntry: e,
    feedback: feedbackBodies.map((body, i) => ({
      id: `f${i}`,
      sessionId: 's1',
      entryId: e.id,
      itemId: '',
      kind: 'comment',
      body,
      createdBy: 'u',
      createdAt: `${i + 1}`,
      deliveredAt: '',
      deliveredVia: '',
      updatedSeq: '1',
    })),
    transitions: [],
    transcriptExcerpt: '',
    supersededBy: [],
  };
}

function card(e: LedgerEntry, reviewable = true) {
  return <LedgerEntryCard sessionId="s1" entry={e} feedback={[]} reviewable={reviewable} onReviewed={() => {}} />;
}

describe('LedgerEntryCard', () => {
  beforeEach(() => {
    vi.mocked(api.getLedgerEntry).mockReset();
    vi.mocked(api.reviewLedgerEntry).mockReset().mockResolvedValue({} as never);
  });

  it('keeps Details available while writing a rejection', async () => {
    const e = entry({ id: 'x', severity: 'review', reviewState: 'pending' });
    vi.mocked(api.getLedgerEntry).mockResolvedValue(detailOf(e, []));
    render(card(e));
    fireEvent.click(screen.getByRole('button', { name: 'Reject' }));
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    expect(await screen.findByText('No captured transcript for this moment.')).toBeInTheDocument();
    expect(screen.getByRole('textbox')).toBeInTheDocument();
  });

  it('reloads an open detail when the entry changes', async () => {
    const e = entry({ id: 'x', updatedSeq: '1' });
    vi.mocked(api.getLedgerEntry).mockResolvedValueOnce(detailOf(e, [])).mockResolvedValue(detailOf(e, ['Looks good']));
    const { rerender } = render(card(e, false));
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    await screen.findByText('No captured transcript for this moment.');
    expect(screen.queryByText(/Looks good/)).not.toBeInTheDocument();
    rerender(card({ ...e, updatedSeq: '2' }, false));
    expect(await screen.findByText(/Looks good/)).toBeInTheDocument();
  });

  it('clears a failed load when a retry succeeds', async () => {
    const e = entry({ id: 'x' });
    vi.mocked(api.getLedgerEntry).mockRejectedValueOnce(new Error('network down')).mockResolvedValue(detailOf(e, []));
    render(card(e, false));
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    expect(await screen.findByText('network down')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Hide details' }));
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    await screen.findByText('No captured transcript for this moment.');
    expect(screen.queryByText('network down')).not.toBeInTheDocument();
  });

  it('renders every option even when the agent repeats one', async () => {
    const e = entry({ id: 'x', optionsConsidered: ['A', 'A', 'B'] });
    vi.mocked(api.getLedgerEntry).mockResolvedValue(detailOf(e, []));
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    render(card(e, false));
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    await waitFor(() => expect(screen.getAllByRole('listitem')).toHaveLength(3));
    expect(errors.mock.calls.some(c => String(c[0]).includes('same key'))).toBe(false);
    errors.mockRestore();
  });

  it('marks observed and provisional entries with chips', () => {
    const e = entry({ id: 'o', source: 'observed', provisional: 'true', undeclared: 'true' });
    render(card(e, false));
    expect(screen.getByText('observed')).toBeInTheDocument();
    expect(screen.getByText('provisional')).toBeInTheDocument();
    expect(screen.getByText('undeclared')).toBeInTheDocument();
  });

  it('shows no observer chips on a declared entry', () => {
    render(card(entry({ id: 'd' }), false));
    expect(screen.queryByText('observed')).not.toBeInTheDocument();
    expect(screen.queryByText('provisional')).not.toBeInTheDocument();
  });

  it('shows confidence, evidence and the match note in the details', async () => {
    const e = entry({
      id: 'o',
      source: 'observed',
      confidence: '0.95',
      evidence: 'I will just skip the flaky test',
      matchedEntryId: 'short',
    });
    vi.mocked(api.getLedgerEntry).mockResolvedValue(detailOf(e, []));
    render(card(e, false));
    expect(screen.queryByText('provisional')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    expect(await screen.findByText('Confidence: 95%')).toBeInTheDocument();
    expect(screen.getByText('I will just skip the flaky test')).toBeInTheDocument();
    expect(screen.getByText('Matches an entry the agent recorded.')).toBeInTheDocument();
  });
});
