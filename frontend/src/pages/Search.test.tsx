import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

vi.mock('../lib/api', () => ({
  api: {
    searchMessages: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { Search } from './Search';

beforeEach(() => {
  vi.mocked(api.searchMessages).mockReset();
});

function renderSearch() {
  return render(
    <MemoryRouter>
      <Search />
    </MemoryRouter>,
  );
}

describe('Search', () => {
  it('disables the search button until a non-empty query is entered', async () => {
    const user = userEvent.setup();
    renderSearch();

    expect(screen.getByRole('button', { name: 'Search' })).toBeDisabled();

    await user.type(screen.getByPlaceholderText('Search your message transcripts…'), 'schedule');
    expect(screen.getByRole('button', { name: 'Search' })).not.toBeDisabled();
  });

  it('shows a loading state while the search is in flight', async () => {
    const user = userEvent.setup();
    let resolveSearch: (v: { messages: never[]; truncated: boolean }) => void = () => {};
    vi.mocked(api.searchMessages).mockReturnValue(
      new Promise(resolve => {
        resolveSearch = resolve;
      }),
    );
    renderSearch();

    await user.type(screen.getByPlaceholderText('Search your message transcripts…'), 'schedule');
    await user.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByRole('button', { name: 'Searching…' })).toBeDisabled();
    resolveSearch({ messages: [], truncated: false });
  });

  it('shows the generic error banner on a failed search', async () => {
    const user = userEvent.setup();
    vi.mocked(api.searchMessages).mockRejectedValue(new Error('500 boom'));
    renderSearch();

    await user.type(screen.getByPlaceholderText('Search your message transcripts…'), 'schedule');
    await user.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByText('500 boom')).toBeInTheDocument();
  });

  // #920: a failed follow-up search must not leave the previous successful
  // search's banner/results on screen underneath the new error — they
  // belong to a different, earlier query.
  it('clears a previous no-matches banner when a follow-up search fails', async () => {
    const user = userEvent.setup();
    vi.mocked(api.searchMessages).mockResolvedValueOnce({ messages: [], truncated: false });
    renderSearch();

    const box = screen.getByPlaceholderText('Search your message transcripts…');
    await user.type(box, 'zzzznomatch');
    await user.click(screen.getByRole('button', { name: 'Search' }));
    expect(await screen.findByText('No messages matched "zzzznomatch".')).toBeInTheDocument();

    vi.mocked(api.searchMessages).mockRejectedValueOnce(new Error('500 boom'));
    await user.clear(box);
    await user.type(box, 'foo');
    await user.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByText('500 boom')).toBeInTheDocument();
    expect(screen.queryByText('No messages matched "zzzznomatch".')).not.toBeInTheDocument();
  });

  // #915: the "no matches" banner must reflect the query that was actually
  // submitted, not whatever the input currently holds — editing the box
  // after a search returns zero results must not silently change the banner
  // without a new search actually running.
  it('shows a no-matches message for the submitted query, unaffected by further typing', async () => {
    const user = userEvent.setup();
    vi.mocked(api.searchMessages).mockResolvedValue({ messages: [], truncated: false });
    renderSearch();

    const input = screen.getByPlaceholderText('Search your message transcripts…');
    await user.type(input, 'zzzznomatch');
    await user.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByText('No messages matched "zzzznomatch".')).toBeInTheDocument();

    await user.type(input, 'more text');
    expect(screen.getByText('No messages matched "zzzznomatch".')).toBeInTheDocument();
  });

  it('renders matching results linking back to their session', async () => {
    const user = userEvent.setup();
    vi.mocked(api.searchMessages).mockResolvedValue({
      messages: [
        { id: 'm1', sessionId: 's1', role: 'user', content: "let's schedule the migration", seq: '000', createdAt: '1700000000000' },
      ],
      truncated: false,
    });
    renderSearch();

    await user.type(screen.getByPlaceholderText('Search your message transcripts…'), 'schedule');
    await user.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByText("let's schedule the migration")).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /let's schedule the migration/ })).toHaveAttribute(
      'href',
      '/sessions/s1',
    );
  });

  it('shows the truncated-results banner when the response reports truncated', async () => {
    const user = userEvent.setup();
    vi.mocked(api.searchMessages).mockResolvedValue({
      messages: [{ id: 'm1', sessionId: 's1', role: 'user', content: 'hit', seq: '000', createdAt: '1700000000000' }],
      truncated: true,
    });
    renderSearch();

    await user.type(screen.getByPlaceholderText('Search your message transcripts…'), 'hit');
    await user.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByText(/there are more\. Refine your search/i)).toBeInTheDocument();
  });
});
