import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, within, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import type { Profile, Prompt } from '../types';

// The API client is the only side-effecting dependency; mock it wholesale so
// each test drives the component purely through UI + resolved values.
vi.mock('../lib/api', () => ({
  api: {
    getPrompts: vi.fn(),
    getProfiles: vi.fn(),
    getSessionProfile: vi.fn(),
    getMessages: vi.fn(),
    renderPrompt: vi.fn(),
    usePrompt: vi.fn(),
    setSessionProfile: vi.fn(),
    getRuns: vi.fn(),
    cancelRun: vi.fn(),
    updateSessionModel: vi.fn(),
    addPrompt: vi.fn(),
    deleteSession: vi.fn(),
  },
}));

// A configurable stream-hook stub. Most tests want a static idle state; the
// #214 test overrides `send`/`output` to drive a completed send. `.current` is
// swapped per test (reset in beforeEach) so the hoisted mock stays stable.
const stream = vi.hoisted(() => ({
  current: {
    output: '' as string,
    isStreaming: false,
    error: null as string | null,
    send: (async () => ({ succeeded: true, stale: false })) as (t: string) => Promise<{ succeeded: boolean; stale: boolean }>,
    reset: (() => {}) as () => void,
    reattachEnded: 0,
  },
}));
vi.mock('../hooks/useStreamMessage', () => ({
  useStreamMessage: () => stream.current,
}));

vi.mock('../context/SessionsContext', () => ({
  useSessions: () => ({
    getSession: (id: string) => ({
      sessionId: id,
      repoUrl: 'https://github.com/owner/repo',
      branch: 'main',
      createdAt: '0',
      harness: 'claude',
      model: 'claude-opus-4-8',
    }),
    removeSession: vi.fn(),
    updateSession: vi.fn(),
  }),
}));

import { api } from '../lib/api';
import { SessionDetail } from './SessionDetail';

function makePrompt(over: Partial<Prompt>): Prompt {
  return {
    id: 'p1',
    userId: 'u1',
    name: 'Greeting',
    body: 'Hello {{name}}!',
    useCount: '0',
    createdAt: '0',
    updatedAt: '0',
    tags: [],
    ...over,
  };
}

function makeProfile(over: Partial<Profile>): Profile {
  return {
    id: 'pa',
    userId: 'u1',
    name: 'Profile A',
    harness: '',
    networkPolicy: 'full',
    credentialMode: 'all',
    credentials: [],
    skillIds: [],
    subagentIds: [],
    mcpServerIds: [],
    createdAt: '0',
    updatedAt: '0',
    ...over,
  };
}

/** A promise whose resolution the test controls, for driving race orderings. */
function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void } {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>(r => {
    resolve = r;
  });
  return { promise, resolve };
}

function renderPage() {
  const root = document.createElement('div');
  root.id = 'root';
  document.body.appendChild(root);
  return render(
    <MemoryRouter initialEntries={['/sessions/s1']}>
      <Routes>
        <Route path="/sessions/:id" element={<SessionDetail />} />
      </Routes>
    </MemoryRouter>,
    { container: root },
  );
}

beforeEach(() => {
  localStorage.clear();
  vi.mocked(api.getPrompts).mockResolvedValue([]);
  vi.mocked(api.getProfiles).mockResolvedValue([]);
  vi.mocked(api.getSessionProfile).mockResolvedValue('');
  vi.mocked(api.getMessages).mockResolvedValue([]);
  vi.mocked(api.usePrompt).mockResolvedValue(undefined);
  vi.mocked(api.setSessionProfile).mockResolvedValue(undefined);
  stream.current = {
    output: '',
    isStreaming: false,
    error: null,
    send: async () => ({ succeeded: true, stale: false }),
    reset: () => {},
    reattachEnded: 0,
  };
});

afterEach(() => {
  vi.clearAllMocks();
  document.querySelectorAll('#root').forEach(el => el.remove());
  // Belt-and-suspenders: the modal's cleanup already restores these on
  // unmount, but reset anyway so a failing test can't leak into the next.
  document.body.style.overflow = '';
  document.body.removeAttribute('inert');
});

describe('SessionDetail template modal', () => {
  it('opens a field per placeholder and inserts the server-rendered text', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([
      makePrompt({ body: 'Hi {{name}} from {{team}}' }),
    ]);
    vi.mocked(api.renderPrompt).mockResolvedValue('Hi Nic from Core');
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p1');

    const dialog = await screen.findByRole('dialog');
    const fields = within(dialog).getAllByRole('textbox');
    expect(fields).toHaveLength(2);
    await user.type(fields[0]!, 'Nic');
    await user.type(fields[1]!, 'Core');
    await user.click(within(dialog).getByRole('button', { name: 'Insert' }));

    expect(api.renderPrompt).toHaveBeenCalledWith('p1', { name: 'Nic', team: 'Core' });
    // Composer receives the rendered text and the modal closes.
    await screen.findByDisplayValue('Hi Nic from Core');
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('cancels without rendering and restores focus to the picker', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([makePrompt({ body: 'Hi {{name}}' })]);
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p1');
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));

    expect(screen.queryByRole('dialog')).toBeNull();
    expect(api.renderPrompt).not.toHaveBeenCalled();
    expect(screen.getByPlaceholderText(/Send a message/)).toHaveValue('');
    // Focus returns to whatever opened the modal (#279).
    expect(document.activeElement).toBe(picker);
  });

  it('locks background scroll and marks #root inert while open, restoring on close', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([makePrompt({ body: 'Hi {{name}}' })]);
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p1');
    await screen.findByRole('dialog');

    const root = document.getElementById('root')!;
    expect(root.hasAttribute('inert')).toBe(true);
    expect(document.body.style.overflow).toBe('hidden');

    await user.keyboard('{Escape}');

    expect(screen.queryByRole('dialog')).toBeNull();
    expect(root.hasAttribute('inert')).toBe(false);
    expect(document.body.style.overflow).toBe('');
  });

  it('inserts a placeholder-free prompt verbatim and records a use', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([
      makePrompt({ id: 'p2', name: 'Plain', body: 'no vars here' }),
    ]);
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p2');

    await screen.findByDisplayValue('no vars here');
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(api.usePrompt).toHaveBeenCalledWith('p2');
    expect(api.renderPrompt).not.toHaveBeenCalled();
  });
});

describe('SessionDetail profile selector', () => {
  it('does not let the in-flight mount fetch revert a manual change (#276)', async () => {
    vi.mocked(api.getProfiles).mockResolvedValue([
      makeProfile({ id: 'pa', name: 'A' }),
      makeProfile({ id: 'pb', name: 'B' }),
    ]);
    // Hold the mount-time "what profile is attached" fetch open so we can
    // resolve it *after* a manual change, reproducing the race.
    const gate = deferred<string>();
    vi.mocked(api.getSessionProfile).mockReturnValue(gate.promise);
    renderPage();
    const user = userEvent.setup();

    const profileSelect = (await screen.findByTitle(/Attach a profile/)) as HTMLSelectElement;
    await user.selectOptions(profileSelect, 'pb');
    expect(api.setSessionProfile).toHaveBeenCalledWith('s1', 'pb');
    expect(profileSelect.value).toBe('pb');

    // The stale fetch now resolves with the server's pre-change value…
    gate.resolve('pa');
    // …and must not clobber the manual choice.
    await waitFor(() => expect(profileSelect.value).toBe('pb'));
  });
});

describe('SessionDetail reattach-completion fold (#319)', () => {
  it('folds a finished reattached run into the transcript when reattachEnded increments', async () => {
    const reset = vi.fn();
    stream.current = {
      output: 'REATTACHED RUN OUTPUT',
      isStreaming: false,
      error: null,
      send: async () => ({ succeeded: true, stale: false }),
      reset,
      reattachEnded: 0,
    };
    // Empty transcript on mount; after the reattached run finishes and folds,
    // the reload returns the now-persisted agent row.
    const agentMsg = {
      id: 'm1',
      sessionId: 's1',
      role: 'agent' as const,
      content: 'persisted agent reply',
      seq: '1',
      createdAt: '0',
    };
    vi.mocked(api.getMessages).mockReset();
    vi.mocked(api.getMessages).mockResolvedValueOnce([]).mockResolvedValue([agentMsg]);

    // A fresh element per render — passing the *same* element object to
    // rerender() hits React's identity bailout and skips reconciliation.
    const makeUi = () => (
      <MemoryRouter initialEntries={['/sessions/s1']}>
        <Routes>
          <Route path="/sessions/:id" element={<SessionDetail />} />
        </Routes>
      </MemoryRouter>
    );
    const root = document.createElement('div');
    root.id = 'root';
    document.body.appendChild(root);
    const { rerender } = render(makeUi(), { container: root });

    // Wait for the page to mount (reattachEnded still 0, so the fold effect
    // hasn't run and reset() hasn't been called yet).
    await screen.findByPlaceholderText(/Send a message/);
    expect(reset).not.toHaveBeenCalled();

    // The reattached run finishes — the hook bumps reattachEnded. Swap the mock
    // to the incremented value and re-render so the component's effect fires.
    stream.current = { ...stream.current, reattachEnded: 1 };
    rerender(makeUi());

    // foldRunIntoTranscript reloads the transcript (now non-empty), so it folds
    // the live panel away: reset() is called and the persisted row is shown.
    await screen.findByText('persisted agent reply');
    await waitFor(() => expect(reset).toHaveBeenCalled());
  });
});

describe('SessionDetail failed-draft recovery for the currently-viewed session (#569)', () => {
  it('surfaces a stale failed send immediately, without waiting for a later revisit', async () => {
    // Simulates navigating away from session s1 and back to it before this
    // send settles: same sessionId, but useStreamMessage's staleness check
    // (a fresh generation) reports it as stale — and it failed.
    stream.current = {
      output: '',
      isStreaming: false,
      error: null,
      send: async () => ({ succeeded: false, stale: true }),
      reset: () => {},
      reattachEnded: 0,
    };
    renderPage();
    const user = userEvent.setup();

    const composer = (await screen.findByPlaceholderText(/Send a message/)) as HTMLTextAreaElement;
    await user.type(composer, 'hello world');
    await user.click(screen.getByRole('button', { name: 'Send' }));

    // handleSend clears the composer synchronously on submit, then the
    // mocked stale+failed send resolves. Since this same session (s1) is
    // still the one on screen, the failed draft should reappear right away
    // instead of requiring a separate future visit to this session.
    await waitFor(() => expect(composer).toHaveValue('hello world'));
    expect(
      screen.getByText(/message you sent to this session earlier failed to go through/i),
    ).toBeInTheDocument();

    // It was reflected directly rather than round-tripped through storage —
    // nothing should be left there for a later mount to pick up again.
    expect(localStorage.getItem('cloud_agents_failed_drafts')).toBeNull();
  });

  it('does not clobber text the user has already typed while the stale send was settling (#631)', async () => {
    // Same stale-and-failed scenario as above, but this time `send` doesn't
    // resolve immediately — it stays pending until the test resolves it
    // itself, giving a window to type a new message into the (already
    // cleared) composer before the stale failure comes back.
    let resolveSend: (result: { succeeded: boolean; stale: boolean }) => void = () => {};
    const sendPromise = new Promise<{ succeeded: boolean; stale: boolean }>(resolve => {
      resolveSend = resolve;
    });
    stream.current = {
      output: '',
      isStreaming: false,
      error: null,
      send: async () => sendPromise,
      reset: () => {},
      reattachEnded: 0,
    };
    renderPage();
    const user = userEvent.setup();

    const composer = (await screen.findByPlaceholderText(/Send a message/)) as HTMLTextAreaElement;
    await user.type(composer, 'hello world');
    await user.click(screen.getByRole('button', { name: 'Send' }));

    // handleSend clears the composer synchronously on submit; the send is
    // still pending. Type something new before it settles.
    await waitFor(() => expect(composer).toHaveValue(''));
    await user.type(composer, 'a brand new message');

    // Now let the stale+failed result land.
    resolveSend({ succeeded: false, stale: true });

    // The new text must survive untouched — restoring 'hello world' here
    // would silently overwrite what the user is actively typing.
    await waitFor(() => expect(localStorage.getItem('cloud_agents_failed_drafts')).not.toBeNull());
    expect(composer).toHaveValue('a brand new message');
    expect(screen.queryByText(/message you sent to this session earlier failed to go through/i)).toBeNull();
  });
});

describe('SessionDetail live output retention', () => {
  it('keeps the completed run visible when the post-send transcript refresh fails (#214)', async () => {
    const reset = vi.fn();
    stream.current = {
      output: 'AGENT REPLY',
      isStreaming: false,
      error: null,
      send: async () => ({ succeeded: true, stale: false }),
      reset,
      reattachEnded: 0,
    };
    // Clean transcript on mount, then fail the post-send reload.
    vi.mocked(api.getMessages).mockReset();
    vi.mocked(api.getMessages).mockResolvedValueOnce([]).mockRejectedValue(new Error('boom'));
    renderPage();
    const user = userEvent.setup();

    const composer = await screen.findByPlaceholderText(/Send a message/);
    await user.type(composer, 'hello');
    await user.click(screen.getByRole('button', { name: 'Send' }));

    // The panel stays on screen (via keepOutput) with the "couldn't refresh"
    // label, instead of the completed run vanishing…
    await screen.findByText(/could not refresh transcript/);
    // …and it wasn't reset, so the run's output is retained.
    expect(reset).not.toHaveBeenCalled();
  });
});

