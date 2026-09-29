import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react';

vi.mock('../lib/api', () => ({
  api: {
    getLedger: vi.fn(),
    getLedgerEntry: vi.fn(),
    reviewLedgerEntry: vi.fn(),
    giveLedgerFeedback: vi.fn(),
    addLedgerItems: vi.fn(),
    setLedgerItemState: vi.fn(),
    syncLedger: vi.fn(),
    getObserverStatus: vi.fn(),
    observeNow: vi.fn(),
  },
}));

import { api } from '../lib/api';
import type { LedgerSnapshot, ObserverStatus } from '../lib/ledger';
import { httpError } from '../test/apiErrors';
import { entry, item } from '../test/ledgerFixtures';
import { LedgerPanel } from './LedgerPanel';

function snapshot(): LedgerSnapshot {
  return {
    cursor: '7',
    unchanged: 'false',
    full: 'true',
    summary: {
      sessionId: 's1',
      total: '2',
      queued: '0',
      inProgress: '1',
      prOpen: '0',
      done: '0',
      blocked: '1',
      needsHuman: '0',
      skipped: '0',
      pendingReview: '2',
      blockingCount: '1',
      undeclaredCount: '0',
      pendingFeedback: '0',
      lastActivityAt: '9',
    },
    items: [
      item({ id: 'gh:acme/shop#1', title: 'Add schema', state: 'in_progress', order: '0' }),
      item({
        id: 'gh:acme/shop#2',
        title: 'Use schema',
        state: 'blocked',
        order: '1',
        blockedBy: ['gh:acme/shop#1'],
        blockedReason: 'Needs the schema from #1',
        recommendation: 'Merge #1 first',
      }),
    ],
    entries: [
      entry({
        id: 'short',
        kind: 'shortcut',
        severity: 'review',
        reviewState: 'pending',
        summary: 'Skipped flaky e2e test',
        recommendation: 'Quarantine it instead',
        itemId: 'gh:acme/shop#1',
        createdSeq: '3',
      }),
      entry({
        id: 'block',
        kind: 'blocker',
        severity: 'blocking',
        reviewState: 'pending',
        summary: 'Blocked: gh:acme/shop#2 - Needs the schema from #1',
        createdSeq: '4',
      }),
      entry({ id: 'd', kind: 'decision', severity: 'info', summary: 'Used a join table', createdSeq: '2' }),
    ],
    feedback: [],
    policyStatus: 'absent',
    policyError: '',
  };
}

function observerStatus(over: Partial<ObserverStatus> = {}): ObserverStatus {
  return {
    enabled: 'true',
    harness: 'claude',
    model: 'claude-haiku-4-5',
    repoAccess: 'diff',
    pending: '0',
    lastPassAt: '',
    lastError: '',
    passesToday: '0',
    maxPassesPerDay: '48',
    ...over,
  };
}

describe('LedgerPanel', () => {
  beforeEach(() => {
    vi.mocked(api.getLedger).mockReset().mockResolvedValue(snapshot());
    vi.mocked(api.reviewLedgerEntry).mockReset().mockResolvedValue({} as never);
    vi.mocked(api.setLedgerItemState).mockReset().mockResolvedValue({} as never);
    vi.mocked(api.giveLedgerFeedback).mockReset().mockResolvedValue({} as never);
    vi.mocked(api.syncLedger).mockReset();
    vi.mocked(api.getObserverStatus).mockReset().mockResolvedValue(observerStatus({ enabled: 'false' }));
    vi.mocked(api.observeNow).mockReset().mockResolvedValue(undefined);
  });

  it('shows the attention queue blocking-first, the work items and what blocks them', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const queue = await screen.findByRole('region', { name: 'Needs your review' });
    const cards = within(queue).getAllByTestId(/^ledger-entry-/);
    expect(cards.map(c => c.getAttribute('data-testid'))).toEqual(['ledger-entry-block', 'ledger-entry-short']);
    expect(within(queue).getByText('Quarantine it instead')).toBeInTheDocument();
    expect(screen.getByText('Add schema')).toBeInTheDocument();
    const blocked = screen.getByRole('region', { name: 'Blocked' });
    expect(within(blocked).getByText('acme/shop#2')).toBeInTheDocument();
    expect(within(blocked).getByText(/in progress/)).toBeInTheDocument();
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuemax', '2');
    expect(api.getLedger).toHaveBeenCalledWith('s1', '0');
  });

  it('requires a reason to reject, then sends it and refreshes', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const card = await screen.findByTestId('ledger-entry-short');
    fireEvent.click(within(card).getByRole('button', { name: 'Reject' }));
    fireEvent.click(within(card).getByRole('button', { name: 'Send rejection' }));
    expect(within(card).getByText('Say what the agent should do instead.')).toBeInTheDocument();
    expect(api.reviewLedgerEntry).not.toHaveBeenCalled();

    fireEvent.change(within(card).getByRole('textbox'), { target: { value: 'Mark it @flaky' } });
    fireEvent.click(within(card).getByRole('button', { name: 'Send rejection' }));
    await waitFor(() => expect(api.reviewLedgerEntry).toHaveBeenCalledWith('s1', 'short', 'reject', 'Mark it @flaky'));
    await waitFor(() => expect(api.getLedger).toHaveBeenLastCalledWith('s1', '7'));
  });

  it('approves in one tap', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const card = await screen.findByTestId('ledger-entry-block');
    fireEvent.click(within(card).getByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(api.reviewLedgerEntry).toHaveBeenCalledWith('s1', 'block', 'approve', ''));
  });

  it('offers the human transitions for a blocked item', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const row = await screen.findByTestId('ledger-item-gh:acme/shop#2');
    expect(within(row).queryByRole('button', { name: 'Reopen' })).not.toBeInTheDocument();
    fireEvent.click(within(row).getByRole('button', { name: 'Unblock' }));
    fireEvent.change(within(row).getByRole('textbox', { name: 'Reason' }), { target: { value: 'done by hand' } });
    fireEvent.click(within(row).getByRole('button', { name: 'Unblock' }));
    await waitFor(() =>
      expect(api.setLedgerItemState).toHaveBeenCalledWith('s1', 'gh:acme/shop#2', 'queued', 'done by hand'),
    );
  });

  it('sends a session-level message to the agent', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Message the agent' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Message for the agent' }), {
      target: { value: 'Also update the changelog' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    await waitFor(() =>
      expect(api.giveLedgerFeedback).toHaveBeenCalledWith('s1', '', 'directive', 'Also update the changelog'),
    );
  });

  it('hides info entries in the timeline until asked', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    fireEvent.click(await screen.findByRole('button', { name: /Timeline/ }));
    const timeline = screen.getByRole('region', { name: 'Timeline' });
    expect(within(timeline).queryByText('Used a join table')).not.toBeInTheDocument();
    fireEvent.click(within(timeline).getByRole('checkbox'));
    expect(within(timeline).getByText('Used a join table')).toBeInTheDocument();
  });

  it('never renders an agent-supplied non-http PR link as a link', async () => {
    const snap = snapshot();
    snap.items = [item({ id: 'gh:acme/shop#1', title: 'Add schema', prUrl: "javascript:alert('x')" })];
    vi.mocked(api.getLedger).mockReset().mockResolvedValue(snap);
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const row = await screen.findByTestId('ledger-item-gh:acme/shop#1');
    expect(within(row).queryByRole('link', { name: 'PR' })).not.toBeInTheDocument();
  });

  it('renders nothing on a backend without the ledger', async () => {
    vi.mocked(api.getLedger).mockReset().mockRejectedValue(httpError(404, 'not found'));
    const { container } = render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    await waitFor(() => expect(container).toBeEmptyDOMElement());
  });

  it('shows an error, not nothing, when a poll fails for another reason', async () => {
    vi.mocked(api.getLedger).mockReset().mockRejectedValue(httpError(500, 'database is locked'));
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    expect(await screen.findByText(/Could not refresh the ledger: database is locked/)).toBeInTheDocument();
  });

  it('says when a long ledger was truncated and how many older entries await review', async () => {
    const snap = snapshot();
    snap.truncated = 'true';
    snap.summary = { ...snap.summary, pendingReview: '5' };
    vi.mocked(api.getLedger).mockReset().mockResolvedValue(snap);
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    expect(await screen.findByText(/only the newest entries are shown/)).toBeInTheDocument();
    expect(screen.getByText(/3 older entries await review in the Inbox/)).toBeInTheDocument();
  });

  it('drops a half-entered transition when a poll moves the item', async () => {
    const first = snapshot();
    const moved = snapshot();
    moved.items = [first.items[0]!, { ...first.items[1]!, state: 'queued' }];
    vi.mocked(api.getLedger).mockReset().mockResolvedValueOnce(first).mockResolvedValue(moved);
    const { rerender } = render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const row = await screen.findByTestId('ledger-item-gh:acme/shop#2');
    fireEvent.click(within(row).getByRole('button', { name: 'Unblock' }));
    fireEvent.change(within(row).getByRole('textbox', { name: 'Reason' }), { target: { value: 'half typed' } });
    // A run ending triggers a catch-up poll that returns the moved item.
    rerender(<LedgerPanel sessionId="s1" isStreaming />);
    rerender(<LedgerPanel sessionId="s1" isStreaming={false} />);
    await waitFor(() => expect(within(screen.getByTestId('ledger-item-gh:acme/shop#2')).queryByRole('textbox', { name: 'Reason' })).not.toBeInTheDocument());
  });
  it('syncs with GitHub on demand and says what moved', async () => {
    vi.mocked(api.syncLedger).mockResolvedValue({ sessions: '1', items: '2', transitions: '1', calls: '5', errors: [] });
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Sync with GitHub' }));
    expect(await screen.findByText('Synced: 1 item moved by changes on GitHub.')).toBeInTheDocument();
    expect(api.syncLedger).toHaveBeenCalledWith('s1');
    await waitFor(() => expect(vi.mocked(api.getLedger).mock.calls.length).toBeGreaterThan(1));
  });

  it('reports GitHub errors from a sync, and a failed sync', async () => {
    vi.mocked(api.syncLedger)
      .mockResolvedValueOnce({ sessions: '1', items: '2', transitions: '0', calls: '1', errors: ['gh:acme/shop#1: (403) forbidden'] })
      .mockRejectedValueOnce(new Error('reconnect GitHub to sync'));
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const button = await screen.findByRole('button', { name: 'Sync with GitHub' });
    fireEvent.click(button);
    expect(await screen.findByText('Synced with 1 GitHub error: gh:acme/shop#1: (403) forbidden')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Sync with GitHub' }));
    expect(await screen.findByText('reconnect GitHub to sync')).toBeInTheDocument();
  });

  it('offers no GitHub sync when no item is a GitHub issue', async () => {
    const local = snapshot();
    local.items = [item({ id: 'local:tidy', title: 'Tidy', state: 'queued', order: '0' })];
    vi.mocked(api.getLedger).mockReset().mockResolvedValue(local);
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    await screen.findByText('Tidy');
    expect(screen.queryByRole('button', { name: 'Sync with GitHub' })).not.toBeInTheDocument();
  });

  it('hides the observer bar when the observer is disabled', async () => {
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    await screen.findByText('Add schema');
    await waitFor(() => expect(api.getObserverStatus).toHaveBeenCalledWith('s1'));
    expect(screen.queryByTestId('observer-bar')).not.toBeInTheDocument();
  });

  it('shows the observer status with its model, and a queued pass', async () => {
    vi.mocked(api.getObserverStatus).mockResolvedValue(observerStatus());
    const { rerender } = render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    expect(await screen.findByText('Observer (claude, claude-haiku-4-5): no passes yet')).toBeInTheDocument();
    vi.mocked(api.getObserverStatus).mockResolvedValue(observerStatus({ pending: '1', lastError: 'harness exited 1' }));
    rerender(<LedgerPanel sessionId="s2" isStreaming={false} />);
    expect(await screen.findByText('Observer (claude, claude-haiku-4-5): pass queued')).toBeInTheDocument();
    expect(screen.getByText('harness exited 1')).toBeInTheDocument();
  });

  it('shows when the last pass ran', async () => {
    vi.mocked(api.getObserverStatus).mockResolvedValue(observerStatus({ lastPassAt: String(Date.now() - 720000) }));
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    const bar = await screen.findByTestId('observer-bar');
    expect(bar).toHaveTextContent(/last pass at /);
  });

  it('runs the observer now and shows the queued message', async () => {
    vi.mocked(api.getObserverStatus).mockResolvedValue(observerStatus());
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Observe now' }));
    expect(await screen.findByText('Queued: the observer runs at the next maintenance pass.')).toBeInTheDocument();
    expect(api.observeNow).toHaveBeenCalledWith('s1');
    await waitFor(() => expect(vi.mocked(api.getObserverStatus).mock.calls.length).toBeGreaterThan(1));
  });

  it('shows an inline error when Observe now fails', async () => {
    vi.mocked(api.getObserverStatus).mockResolvedValue(observerStatus());
    vi.mocked(api.observeNow).mockRejectedValue(new Error('no observer enabled'));
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Observe now' }));
    expect(await screen.findByText('no observer enabled')).toBeInTheDocument();
  });

  it('hides the observer bar when the backend has no observer endpoint (404)', async () => {
    vi.mocked(api.getObserverStatus).mockRejectedValue(httpError(404));
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    await screen.findByText('Add schema');
    await waitFor(() => expect(api.getObserverStatus).toHaveBeenCalled());
    expect(screen.queryByTestId('observer-bar')).not.toBeInTheDocument();
  });

  it('keeps observed entries that matched a declared entry out of the timeline until info is shown', async () => {
    const snap = snapshot();
    snap.entries = [
      entry({
        id: 'obs',
        source: 'observed',
        severity: 'info',
        matchedEntryId: 'short',
        summary: 'Observed skipped test',
        createdSeq: '5',
      }),
    ];
    vi.mocked(api.getLedger).mockReset().mockResolvedValue(snap);
    render(<LedgerPanel sessionId="s1" isStreaming={false} />);
    fireEvent.click(await screen.findByRole('button', { name: /Timeline/ }));
    expect(screen.queryByText('Observed skipped test')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('checkbox', { name: /Show info/ }));
    expect(screen.getByText('Observed skipped test')).toBeInTheDocument();
  });
});
