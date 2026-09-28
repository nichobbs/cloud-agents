import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

vi.mock('../lib/api', () => ({
  api: {
    getLedgerInbox: vi.fn(),
    reviewLedgerEntry: vi.fn(),
    getLedgerEntry: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { entry } from '../test/ledgerFixtures';
import { Inbox } from './Inbox';

function renderInbox() {
  return render(
    <MemoryRouter>
      <Inbox />
    </MemoryRouter>,
  );
}

describe('Inbox', () => {
  beforeEach(() => {
    vi.mocked(api.getLedgerInbox).mockReset();
    vi.mocked(api.reviewLedgerEntry).mockReset().mockResolvedValue({} as never);
  });

  it('groups pending reviews by session with a link to each', async () => {
    vi.mocked(api.getLedgerInbox).mockResolvedValue([
      { ledgerEntry: entry({ id: 'b', sessionId: 's1', kind: 'blocker', severity: 'blocking', reviewState: 'pending', summary: 'Blocked on #1' }), repoUrl: 'https://github.com/acme/shop', branch: 'main' },
      { ledgerEntry: entry({ id: 'q', sessionId: 's2', kind: 'question', severity: 'review', reviewState: 'pending', summary: 'Which API?' }), repoUrl: 'https://github.com/acme/api', branch: 'dev' },
      { ledgerEntry: entry({ id: 's', sessionId: 's1', kind: 'shortcut', severity: 'review', reviewState: 'pending', summary: 'Skipped a test' }), repoUrl: 'https://github.com/acme/shop', branch: 'main' },
    ]);
    renderInbox();
    const shop = await screen.findByRole('region', { name: 'Session acme/shop' });
    expect(within(shop).getAllByTestId(/^ledger-entry-/)).toHaveLength(2);
    expect(within(shop).getByRole('link', { name: 'Open session' })).toHaveAttribute('href', '/sessions/s1');
    expect(screen.getByRole('region', { name: 'Session acme/api' })).toBeInTheDocument();
    expect(screen.getByText(/3 waiting, 1 blocking/)).toBeInTheDocument();
  });

  it('reviews from the inbox and reloads', async () => {
    vi.mocked(api.getLedgerInbox)
      .mockResolvedValueOnce([
        { ledgerEntry: entry({ id: 'q', sessionId: 's2', kind: 'question', severity: 'review', reviewState: 'pending', summary: 'Which API?' }), repoUrl: 'https://github.com/acme/api', branch: 'dev' },
      ])
      .mockResolvedValue([]);
    renderInbox();
    const card = await screen.findByTestId('ledger-entry-q');
    fireEvent.click(within(card).getByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(api.reviewLedgerEntry).toHaveBeenCalledWith('s2', 'q', 'approve', ''));
    expect(await screen.findByText('Nothing needs your review.')).toBeInTheDocument();
  });

  it('ignores a reload that finishes after a newer one', async () => {
    const both = [
      { ledgerEntry: entry({ id: 'q', sessionId: 's2', kind: 'question', severity: 'review', reviewState: 'pending', summary: 'Which API?' }), repoUrl: 'https://github.com/acme/api', branch: 'dev' },
      { ledgerEntry: entry({ id: 'r', sessionId: 's2', kind: 'shortcut', severity: 'review', reviewState: 'pending', summary: 'Skipped a test' }), repoUrl: 'https://github.com/acme/api', branch: 'dev' },
    ];
    let resolveOlder: (v: typeof both) => void = () => {};
    vi.mocked(api.getLedgerInbox)
      .mockResolvedValueOnce(both)
      .mockImplementationOnce(() => new Promise(r => (resolveOlder = r)))
      .mockResolvedValue([]);
    renderInbox();
    // Two reviews in quick succession: the first one's reload is still out
    // when the second one's reload lands.
    fireEvent.click(within(await screen.findByTestId('ledger-entry-q')).getByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(api.getLedgerInbox).toHaveBeenCalledTimes(2));
    fireEvent.click(within(screen.getByTestId('ledger-entry-r')).getByRole('button', { name: 'Approve' }));
    expect(await screen.findByText('Nothing needs your review.')).toBeInTheDocument();
    resolveOlder(both);
    await new Promise(r => setTimeout(r, 0));
    expect(screen.queryByTestId('ledger-entry-q')).not.toBeInTheDocument();
    expect(screen.getByText('Nothing needs your review.')).toBeInTheDocument();
  });
});
