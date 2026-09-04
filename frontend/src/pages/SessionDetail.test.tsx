import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, within, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import type { AttachmentInput, Message, Profile, Prompt } from '../types';

// Spies on the real useNavigate (rather than replacing it) so the #898
// regression test below can assert on the replace-history call while every
// other test in this file keeps exercising real react-router navigation
// unmodified.
const mockNavigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async importOriginal => {
  const actual = await importOriginal<typeof import('react-router-dom')>();
  return {
    ...actual,
    useNavigate: () => ((...args: Parameters<ReturnType<typeof actual.useNavigate>>) => {
      mockNavigate(...args);
    }) as ReturnType<typeof actual.useNavigate>,
  };
});

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
    restartContainer: vi.fn(),
    updateSessionModel: vi.fn(),
    addPrompt: vi.fn(),
    deleteSession: vi.fn(),
    markSessionViewed: vi.fn(),
    listAttachments: vi.fn(),
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
    toolMode: 'all',
    tools: [],
    createdAt: '0',
    updatedAt: '0',
    ...over,
  };
}

function makeMessage(over: Partial<Message>): Message {
  return {
    id: 'm1',
    sessionId: 's1',
    role: 'user',
    content: '',
    seq: '0',
    createdAt: '0',
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

function renderPage(initialEntries: Array<string | { pathname: string; state?: unknown; hash?: string }> = ['/sessions/s1']) {
  const root = document.createElement('div');
  root.id = 'root';
  document.body.appendChild(root);
  return render(
    <MemoryRouter initialEntries={initialEntries}>
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
  vi.mocked(api.markSessionViewed).mockResolvedValue(undefined);
  vi.mocked(api.listAttachments).mockResolvedValue([]);
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

describe('SessionDetail retry-run button', () => {
  it('retries the message that actually failed, not the last successful one', async () => {
    // A prior, already-succeeded exchange sits in the transcript. `messages`
    // is only reloaded on a SUCCESSFUL send (foldRunIntoTranscript), so it
    // never grows to include the send this test is about to fail — the bug
    // was reading "the last user message in `messages`" as a stand-in for
    // "the message that just failed", which resolved to this earlier one
    // instead.
    vi.mocked(api.getMessages).mockResolvedValue([
      makeMessage({ id: 'm1', role: 'user', content: 'first message', seq: '0' }),
      makeMessage({ id: 'm2', role: 'agent', content: 'first reply', seq: '1' }),
    ]);
    const sendSpy = vi.fn(async (_text: string) => {
      stream.current = { ...stream.current, error: 'container crashed' };
      return { succeeded: false, stale: false };
    });
    stream.current = {
      output: '',
      isStreaming: false,
      error: null,
      send: sendSpy,
      reset: () => {},
      reattachEnded: 0,
    };
    renderPage();
    const user = userEvent.setup();

    const composer = (await screen.findByPlaceholderText(/Send a message/)) as HTMLTextAreaElement;
    await user.type(composer, 'second message, this one fails');
    await user.click(screen.getByRole('button', { name: 'Send' }));

    const retryBtn = await screen.findByRole('button', { name: /Retry run/ });
    sendSpy.mockClear();
    await user.click(retryBtn);

    expect(sendSpy).toHaveBeenCalledWith('second message, this one fails');
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

describe('SessionDetail profile-attach-error handoff (#898)', () => {
  it('shows the NewSession handoff banner and immediately strips it from history', async () => {
    renderPage([{ pathname: '/sessions/s1', state: { profileAttachError: 'profile deleted' } }]);

    await screen.findByText(/Profile not attached: profile deleted/);

    // The stale-history fix (#898): the entry that carried the handoff state
    // is replaced right away, so a later browser back/forward into this
    // exact URL can't resurrect an already-resolved banner.
    await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith('/sessions/s1', { replace: true }));
  });

  it('preserves an existing #message-… deep-link hash when replacing history (#899)', async () => {
    renderPage([{
      pathname: '/sessions/s1',
      hash: '#message-m1',
      state: { profileAttachError: 'profile deleted' },
    }]);

    await screen.findByText(/Profile not attached: profile deleted/);

    await waitFor(() =>
      expect(mockNavigate).toHaveBeenCalledWith('/sessions/s1#message-m1', { replace: true }),
    );
  });

  it('clears the banner on a successful manual profile change, and does not replace history again', async () => {
    const profile: Profile = {
      id: 'p1',
      userId: 'u1',
      name: 'sandbox',
      harness: '',
      networkPolicy: 'none',
      credentialMode: 'all',
      credentials: [],
      skillIds: [],
      subagentIds: [],
      mcpServerIds: [],
      toolMode: 'all',
      tools: [],
      createdAt: '0',
      updatedAt: '0',
    };
    vi.mocked(api.getProfiles).mockResolvedValue([profile]);
    renderPage([{ pathname: '/sessions/s1', state: { profileAttachError: 'profile deleted' } }]);
    const user = userEvent.setup();

    await screen.findByText(/Profile not attached: profile deleted/);
    await waitFor(() => expect(mockNavigate).toHaveBeenCalledTimes(1));

    await user.selectOptions(await screen.findByTitle(/Attach a profile/), 'p1');

    await waitFor(() => expect(screen.queryByText(/Profile not attached/)).toBeNull());
    // Resolving it via the selector is a plain React-state clear — it must
    // not trigger a second history replace.
    expect(mockNavigate).toHaveBeenCalledTimes(1);
  });
});

describe('SessionDetail mark-viewed (attention tracking)', () => {
  it('marks the session viewed once on mount, fire-and-forget', async () => {
    renderPage();
    await screen.findByPlaceholderText(/Send a message/);
    await waitFor(() => expect(api.markSessionViewed).toHaveBeenCalledWith('s1'));
    expect(api.markSessionViewed).toHaveBeenCalledTimes(1);
  });

  it('keeps rendering normally when the viewed endpoint is missing (older backend)', async () => {
    vi.mocked(api.markSessionViewed).mockRejectedValue(new Error('404 not found'));
    renderPage();
    // The rejection is swallowed; the page still mounts fine.
    await screen.findByPlaceholderText(/Send a message/);
  });
});

describe('SessionDetail stale attached profile (#900/#901)', () => {
  const liveProfile: Profile = {
    id: 'p-live',
    userId: 'u1',
    name: 'Live Profile',
    harness: '',
    networkPolicy: 'full',
    credentialMode: 'all',
    credentials: [],
    skillIds: [],
    subagentIds: [],
    mcpServerIds: [],
    toolMode: 'all',
    tools: [],
    createdAt: '0',
    updatedAt: '0',
  };

  it("shows a distinct 'profile deleted' option for a stale attached profile id, alongside other profiles", async () => {
    vi.mocked(api.getProfiles).mockResolvedValue([liveProfile]);
    vi.mocked(api.getSessionProfile).mockResolvedValue('p-deleted-12345678');
    renderPage();

    const select = await screen.findByTitle(/Attach a profile/);
    await waitFor(() => expect(within(select).getByText(/p-delete… \(profile deleted\)/)).toBeInTheDocument());
    expect(within(select).getByRole('option', { name: 'Live Profile' })).toBeInTheDocument();
  });

  it('still surfaces the selector for a stale attached profile id even when the account has zero profiles (#901)', async () => {
    vi.mocked(api.getProfiles).mockResolvedValue([]);
    vi.mocked(api.getSessionProfile).mockResolvedValue('p-deleted-12345678');
    renderPage();

    const select = await screen.findByTitle(/Attach a profile/);
    expect(within(select).getByText(/p-delete… \(profile deleted\)/)).toBeInTheDocument();
  });
});

describe('SessionDetail attachment picker', () => {
  function oversizedFile(name: string, bytes: number): File {
    const file = new File(['x'], name, { type: 'application/octet-stream' });
    // Real 20MB+ payloads would make this test slow for no benefit — the
    // component only reads `file.size`, so override just that.
    Object.defineProperty(file, 'size', { value: bytes });
    return file;
  }

  it('rejects a file over the 20 MB per-file cap with a notice, and never stages it', async () => {
    renderPage();
    const user = userEvent.setup();
    const input = screen.getByLabelText('Attach files') as HTMLInputElement;

    const tooBig = oversizedFile('huge.bin', 21 * 1024 * 1024);
    await user.upload(input, tooBig);

    await waitFor(() => expect(screen.getByText(/over the 20\.0 MB per-file limit/)).toBeInTheDocument());
    expect(screen.queryByText('huge.bin')).not.toBeInTheDocument();
    // Nothing staged and no text typed — Send stays disabled.
    expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled();
  });

  it('stages an accepted file as a chip and enables Send with no text typed', async () => {
    renderPage();
    const user = userEvent.setup();
    const input = screen.getByLabelText('Attach files') as HTMLInputElement;

    const small = new File(['hello world'], 'notes.txt', { type: 'text/plain' });
    await user.upload(input, small);

    await waitFor(() => expect(screen.getByText('notes.txt')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: 'Send' })).toBeEnabled();
  });

  it('sends a file-only message (empty text) with the staged attachment in the payload', async () => {
    const sendSpy = vi.fn(async (_text: string, _attachments?: AttachmentInput[]) => ({ succeeded: true, stale: false }));
    stream.current = { ...stream.current, send: sendSpy };
    renderPage();
    const user = userEvent.setup();
    const input = screen.getByLabelText('Attach files') as HTMLInputElement;

    const small = new File(['hello world'], 'notes.txt', { type: 'text/plain' });
    await user.upload(input, small);
    await waitFor(() => expect(screen.getByText('notes.txt')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Send' }));

    await waitFor(() => expect(sendSpy).toHaveBeenCalled());
    const [text, attachments] = sendSpy.mock.calls[0]!;
    expect(text).toBe('');
    expect(attachments).toHaveLength(1);
    expect(attachments![0]!.fileName).toBe('notes.txt');
    expect(attachments![0]!.mimeType).toBe('text/plain');
  });

  it('removing a staged attachment via its × button disables Send again', async () => {
    renderPage();
    const user = userEvent.setup();
    const input = screen.getByLabelText('Attach files') as HTMLInputElement;

    const small = new File(['hello world'], 'notes.txt', { type: 'text/plain' });
    await user.upload(input, small);
    await waitFor(() => expect(screen.getByText('notes.txt')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: '×' }));

    expect(screen.queryByText('notes.txt')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled();
  });

  it('rejects an SVG file at pick-time with a notice, mirroring the server mimeType blocklist (#1006)', async () => {
    renderPage();
    const user = userEvent.setup();
    const input = screen.getByLabelText('Attach files') as HTMLInputElement;

    const evilSvg = new File(['<svg onload="alert(1)"></svg>'], 'evil.svg', { type: 'image/svg+xml' });
    await user.upload(input, evilSvg);

    await waitFor(() => expect(screen.getByText(/unsupported file type/)).toBeInTheDocument());
    expect(screen.queryByText('evil.svg')).not.toBeInTheDocument();
    // Nothing staged and no text typed — Send stays disabled, same as the
    // existing oversize-file rejection above: the file never even reaches
    // readFileAsAttachmentInput (no base64 encoding wasted on it).
    expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled();
  });

  it('rejects HTML case-insensitively and with a MIME parameter suffix, matching the server check (#1006)', async () => {
    renderPage();
    const user = userEvent.setup();
    const input = screen.getByLabelText('Attach files') as HTMLInputElement;

    const evilHtml = new File(['<script>alert(1)</script>'], 'evil.html', { type: 'TEXT/HTML; charset=utf-8' });
    await user.upload(input, evilHtml);

    await waitFor(() => expect(screen.getByText(/unsupported file type/)).toBeInTheDocument());
    expect(screen.queryByText('evil.html')).not.toBeInTheDocument();
  });
});

